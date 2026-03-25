// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlexComboMachine} from "../src/FlexComboMachine.sol";
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

contract MockHotContest {
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

contract FlexComboMachineTest is Test {
	using MessageHashUtils for bytes32;

	FlexComboMachine public flex;
	EventMarketRegistry public registry;
	MockUSDC public usdc;
	MockCreditToken public creditToken;
	MockHotContest public treasury;

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

	uint16 internal constant MIN_PICKS = 3;
	uint16 internal constant MAX_PICKS = 6;
	uint256 internal constant MAX_MULTIPLIER = 25000;

	function setUp() public {
		bettor = vm.addr(bettorPk);
		authority = vm.addr(authorityPk);

		// Deploy tokens
		usdc = new MockUSDC();
		creditToken = new MockCreditToken();
		treasury = new MockHotContest(address(creditToken), address(usdc));

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

		// Deploy FlexComboMachine via proxy
		FlexComboMachine flexImpl = new FlexComboMachine();
		bytes memory flexInit = abi.encodeCall(
			FlexComboMachine.initialize,
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
		TransparentUpgradeableProxy flexProxy = new TransparentUpgradeableProxy(
			address(flexImpl),
			makeAddr("flexAdmin"),
			flexInit
		);
		flex = FlexComboMachine(address(flexProxy));

		// Setup: authorize flex as writer in registry
		vm.prank(contractOwner);
		registry.addAuthorizedWriter(address(flex));

		// Setup: add compliance officer
		vm.prank(contractOwner);
		flex.addComplianceOfficer(complianceOfficer);

		// Setup: add default flex multiplier config
		// 2D: [picks_count_index][lost_count] => multiplier
		// Row 0 (3 picks): [300, 100, 0]
		// Row 1 (4 picks): [600, 150, 0, 0]
		// Row 2 (5 picks): [1000, 200, 40, 0, 0]
		// Row 3 (6 picks): [2500, 200, 40, 0, 0, 0]
		uint256[][] memory mults = new uint256[][](4);

		mults[0] = new uint256[](3);
		mults[0][0] = 300;
		mults[0][1] = 100;
		mults[0][2] = 0;

		mults[1] = new uint256[](4);
		mults[1][0] = 600;
		mults[1][1] = 150;
		mults[1][2] = 0;
		mults[1][3] = 0;

		mults[2] = new uint256[](5);
		mults[2][0] = 1000;
		mults[2][1] = 200;
		mults[2][2] = 40;
		mults[2][3] = 0;
		mults[2][4] = 0;

		mults[3] = new uint256[](6);
		mults[3][0] = 2500;
		mults[3][1] = 200;
		mults[3][2] = 40;
		mults[3][3] = 0;
		mults[3][4] = 0;
		mults[3][5] = 0;

		vm.prank(contractOwner);
		flex.addMultiplierConfig(mults);

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
		returns (FlexComboMachine.Pick[] memory, FlexComboMachine.LazyCreateEventMarket[] memory)
	{
		FlexComboMachine.Pick[] memory picks = new FlexComboMachine.Pick[](marketIds.length);
		FlexComboMachine.LazyCreateEventMarket[]
			memory lazys = new FlexComboMachine.LazyCreateEventMarket[](marketIds.length);
		for (uint256 i = 0; i < marketIds.length; i++) {
			picks[i] = FlexComboMachine.Pick({
				event_market_id: bytes12(marketIds[i]),
				outcome_id: bytes12(outcomeIds[i])
			});
			lazys[i] = FlexComboMachine.LazyCreateEventMarket({
				event_market_id: bytes12(marketIds[i]),
				min_settlement_ts: uint40(block.timestamp + 1 hours)
			});
		}
		return (picks, lazys);
	}

	function _signPlaceBet(
		FlexComboMachine.Pick[] memory picks,
		FlexComboMachine.LazyCreateEventMarket[] memory lazys,
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
				address(flex),
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
		FlexComboMachine.Pick[] memory picks,
		uint256 deadline
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(SETTLE_BET_TYPEHASH, block.chainid, address(flex), betId, picks, deadline)
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
		FlexComboMachine.Pick[] memory picks,
		uint256 deadline,
		uint256 nonce,
		uint256 pk
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(
				CANCEL_BET_TYPEHASH,
				block.chainid,
				address(flex),
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

	/// @dev Places a standard 3-pick bet with USDC, returns bet_id
	function _placeDefaultBet()
		internal
		returns (
			uint256 betId,
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
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
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		)
	{
		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(picks, lazys) = _picks(mids, oids);

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = flex.wallet_nonce(bettor);

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

		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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
		betId = flex.getTotalBetsCount() - 1;
	}

	/// @dev Places a 5-pick bet
	function _place5PickBet()
		internal
		returns (
			uint256 betId,
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		)
	{
		uint96[] memory mids = new uint96[](5);
		mids[0] = 10;
		mids[1] = 20;
		mids[2] = 30;
		mids[3] = 40;
		mids[4] = 50;
		uint96[] memory oids = new uint96[](5);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		oids[3] = 400;
		oids[4] = 500;
		(picks, lazys) = _picks(mids, oids);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = flex.wallet_nonce(bettor);

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

		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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
		betId = flex.getTotalBetsCount() - 1;
	}

	function _settleAllMarkets(
		FlexComboMachine.Pick[] memory picks,
		bytes12[] memory winningOutcomes
	) internal {
		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		for (uint256 i = 0; i < picks.length; i++) {
			bytes12 marketId = picks[i].event_market_id;
			bytes12 outcome = winningOutcomes[i];
			if (outcome == bytes12(0)) {
				registry.voidEventMarket(marketId, deadline, _signVoidEvent(marketId, deadline));
			} else {
				registry.settleEventMarket(
					marketId,
					outcome,
					deadline,
					_signSettleEvent(marketId, outcome, deadline)
				);
			}
		}
	}

	// ─── Initialize ───

	/// @dev Verifies that all state variables are correctly set after proxy initialization:
	/// owner, automated authority, registry address, treasury address, bet limits (min=0.001, max=100k),
	/// and config limits (min_picks=3, max_picks=6, max_multiplier=25000).
	function test_initialize() public view {
		assertEq(flex.owner(), contractOwner);
		assertEq(flex.automated_authority_address(), authority);
		assertEq(flex.event_market_registry_address(), address(registry));
		assertEq(flex.hot_treasury_address(), address(treasury));
		(uint128 minBet, uint128 maxBet) = flex.bet_limits();
		assertEq(minBet, 1000000000000000);
		assertEq(maxBet, 100_000e18);
		(uint16 minPicks, uint16 maxPicks, uint128 maxMult) = flex.config_limits();
		assertEq(minPicks, MIN_PICKS);
		assertEq(maxPicks, MAX_PICKS);
		assertEq(maxMult, MAX_MULTIPLIER);
	}

	// ─── Place Bet ───

	/// @dev Places a valid 3-pick, 10 USDC bet and verifies:
	/// - bet_id is 0 (first bet)
	/// - total bets count incremented to 1
	/// - 10 USDC (10e6 in coin decimals) deducted from bettor and sent to treasury
	/// - wallet nonce incremented from 0 to 1
	function test_placeBet_success() public {
		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		(uint256 betId, , ) = _placeDefaultBet();

		assertEq(betId, 0);
		assertEq(flex.getTotalBetsCount(), 1);
		assertEq(usdc.balanceOf(bettor), bettorBalBefore - 10e6);
		assertEq(flex.wallet_nonce(bettor), 1);
	}

	/// @dev Verifies that the wallet nonce increments with each bet placed.
	/// After placing two bets (with different market IDs), the nonce should be 2.
	/// The nonce prevents signature replay — each bet requires a signature bound to the current nonce.
	function test_placeBet_incrementsNonce() public {
		_placeDefaultBet();
		assertEq(flex.wallet_nonce(bettor), 1);

		// second bet needs different market IDs
		uint96[] memory mids = new uint96[](3);
		mids[0] = 4;
		mids[1] = 5;
		mids[2] = 6;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 400;
		oids[1] = 500;
		oids[2] = 600;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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

		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

		assertEq(flex.wallet_nonce(bettor), 2);
	}

	/// @dev Verifies that placing a bet with bet_size=1 wei (far below the minimum of 0.001 tokens)
	/// reverts with InvalidBetSize. The minimum bet limit is 1e15 (0.001 in 18 decimals).
	function test_placeBet_revertsBelowMinBetSize() public {
		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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

		vm.expectRevert(FlexComboMachine.InvalidBetSize.selector);
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	/// @dev Verifies that placing a bet with 200,000 tokens (above the max of 100,000 tokens)
	/// reverts with InvalidBetSize.
	function test_placeBet_revertsAboveMaxBetSize() public {
		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

		uint128 betSize = 200_000e18;
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

		vm.expectRevert(FlexComboMachine.InvalidBetSize.selector);
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	/// @dev Verifies that a blacklisted wallet cannot place a bet.
	/// The bettor is added to the blacklist by a compliance officer, then any placeBet call
	/// with that bettor as owner reverts with Unauthorized.
	function test_placeBet_revertsBlacklistedWallet() public {
		vm.prank(complianceOfficer);
		flex.addToBlacklist(bettor);

		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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

		vm.expectRevert(FlexComboMachine.Unauthorized.selector);
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	/// @dev Verifies that a bet with a deadline in the past (block.timestamp - 1) reverts with InvalidInput.
	/// The deadline is a meta-transaction expiry to prevent stale signatures from being submitted.
	function test_placeBet_revertsExpiredDeadline() public {
		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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

		vm.expectRevert(FlexComboMachine.InvalidInput.selector);
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	/// @dev Verifies that placeBet reverts when the contract is paused by the owner.
	/// OpenZeppelin's Pausable modifier blocks all whenNotPaused functions.
	function test_placeBet_revertsWhenPaused() public {
		vm.prank(contractOwner);
		flex.pause();

		uint96[] memory mids = new uint96[](3);
		mids[0] = 1;
		mids[1] = 2;
		mids[2] = 3;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	/// @dev Verifies that placing a bet with only 2 picks reverts with InvalidPicksCount,
	/// since the contract is configured with min_picks_count=3.
	function test_placeBet_revertsTooFewPicks() public {
		// 2 picks, min is 3
		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(
			FlexComboMachine.Pick[] memory picks,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

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

		vm.expectRevert(FlexComboMachine.InvalidPicksCount.selector);
		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
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

	// ─── Settle Bet: All Wins ───

	/// @dev 3-pick bet where all picks win. Flex play multiplier lookup:
	/// picks_count_index = 3 - 3 = 0, lost_count = 0 → mults[0][0] = 300 (x3.00)
	/// Payout = 10 USDC * 3.00 = 30 USDC. Bet status changes to SETTLED (5).
	function test_settleBet_allWins() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// All 3 markets won
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100));
		outcomes[1] = bytes12(uint96(200));
		outcomes[2] = bytes12(uint96(300));
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 3 picks, 0 lost → multiplier = 300 (x3.00) → payout = 10e18 * 300 / 100 = 30e18 = 30e6 USDC
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 30e6);

		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 5); // STATUS_SETTLED
	}

	// ─── Settle Bet: Partial Win (1 loss) ───

	/// @dev 3-pick bet where 2 picks win and 1 loses. This is the key flex play feature —
	/// unlike power play (ComboMachine), losing 1 pick doesn't mean total loss.
	/// picks_count_index = 0, lost_count = 1 → mults[0][1] = 100 (x1.00)
	/// Payout = 10 USDC * 1.00 = 10 USDC (bettor gets their money back, no profit).
	function test_settleBet_partialWin_1loss() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// 2 wins, 1 loss
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(uint96(999)); // loss
		outcomes[2] = bytes12(uint96(300)); // win
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 3 picks, 1 lost → multiplier = 100 (x1.00) → payout = 10e18 * 100 / 100 = 10e18 = 10e6 USDC
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
	}

	// ─── Settle Bet: All Losses ───

	/// @dev 3-pick bet where all 3 picks lose. lost_count = 3, but the multiplier row
	/// for 3 picks only has 3 entries (indices 0,1,2), so lost_count >= row.length.
	/// When lost_count >= row length, payout is 0 (total loss). No USDC returned.
	function test_settleBet_allLosses() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// All 3 markets lost (different outcomes)
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(999));
		outcomes[1] = bytes12(uint96(998));
		outcomes[2] = bytes12(uint96(997));
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 3 picks, 3 lost → lost_count=3 >= row length(3) → payout = 0
		assertEq(usdc.balanceOf(bettor), bettorBalBefore);
	}

	// ─── Settle Bet: 2 losses out of 3 (multiplier = 0) ───

	/// @dev 3-pick bet with 2 losses and 1 win. picks_count_index = 0, lost_count = 2.
	/// mults[0][2] = 0 — the config explicitly sets this to 0, meaning 2 losses out of 3
	/// results in no payout even though the multiplier entry exists.
	function test_settleBet_2lossesOf3() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// 1 win, 2 losses
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(uint96(999)); // loss
		outcomes[2] = bytes12(uint96(997)); // loss
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 3 picks, 2 lost → multiplier = mults[0][2] = 0 → no payout
		assertEq(usdc.balanceOf(bettor), bettorBalBefore);
	}

	// ─── Settle Bet: 5 picks, partial win ───

	/// @dev 5-pick bet with 4 wins and 1 loss. Demonstrates the flex advantage with more picks:
	/// remaining_picks = 5, picks_count_index = 5 - 3 = 2, lost_count = 1
	/// → mults[2][1] = 200 (x2.00). Payout = 10 USDC * 2.00 = 20 USDC.
	/// In power play, 1 loss would mean total loss. In flex play, the bettor still profits.
	function test_settleBet_5picks_1loss() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _place5PickBet();

		// 4 wins, 1 loss
		bytes12[] memory outcomes = new bytes12[](5);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(uint96(200)); // win
		outcomes[2] = bytes12(uint96(999)); // loss
		outcomes[3] = bytes12(uint96(400)); // win
		outcomes[4] = bytes12(uint96(500)); // win
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 5 picks, 1 lost → picks_count_index=2, lost_count=1 → multiplier = 200 (x2.00)
		// payout = 10e18 * 200 / 100 = 20e18 = 20e6 USDC
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 20e6);
	}

	/// @dev 5-pick bet with 3 wins and 2 losses. Tests the smallest non-zero flex multiplier:
	/// picks_count_index = 2, lost_count = 2 → mults[2][2] = 40 (x0.40)
	/// Payout = 10 USDC * 0.40 = 4 USDC. Bettor loses 60% of their stake but still gets something back.
	function test_settleBet_5picks_2losses() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _place5PickBet();

		// 3 wins, 2 losses
		bytes12[] memory outcomes = new bytes12[](5);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(uint96(999)); // loss
		outcomes[2] = bytes12(uint96(300)); // win
		outcomes[3] = bytes12(uint96(998)); // loss
		outcomes[4] = bytes12(uint96(500)); // win
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// 5 picks, 2 lost → picks_count_index=2, lost_count=2 → multiplier = 40 (x0.40)
		// payout = 10e18 * 40 / 100 = 4e18 = 4e6 USDC
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 4e6);
	}

	// ─── Settle Bet: Voided Events ───

	/// @dev 3-pick bet where 2 events are voided. Voided events are excluded from settlement:
	/// remaining_picks = 3 - 2 = 1. Since 1 < min_picks_count (3), the bet is automatically
	/// refunded — full stake returned to bettor. Status changes to REFUNDED (2).
	function test_settleBet_voidedMarket_refundsIfBelowMinPicks() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// 1 won, 2 voided → remaining=1 < min_picks(3) → refund
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(0); // voided
		outcomes[2] = bytes12(0); // voided
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// Refund: 10 USDC back
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 2); // STATUS_REFUNDED
	}

	/// @dev 5-pick bet where 1 event is voided, 1 is lost, 3 are won.
	/// Voided events shrink the effective bet: remaining_picks = 5 - 1 = 4.
	/// The multiplier is looked up using the 4-pick row (index 1), not the original 5-pick row.
	/// picks_count_index = 4 - 3 = 1, lost_count = 1 → mults[1][1] = 150 (x1.50)
	/// Payout = 10 USDC * 1.50 = 15 USDC.
	function test_settleBet_voidedMarket_recalculatesMultiplier() public {
		// 5 picks, 1 voided → remaining=4 picks, use row index for 4 picks
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _place5PickBet();

		// 3 wins, 1 loss, 1 voided → remaining=4, lost_count=1
		bytes12[] memory outcomes = new bytes12[](5);
		outcomes[0] = bytes12(uint96(100)); // win
		outcomes[1] = bytes12(uint96(200)); // win
		outcomes[2] = bytes12(0); // voided
		outcomes[3] = bytes12(uint96(998)); // loss
		outcomes[4] = bytes12(uint96(500)); // win
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// remaining=4, picks_count_index=1, lost_count=1 → multiplier = 150 (x1.50)
		// payout = 10e18 * 150 / 100 = 15e18 = 15e6 USDC
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 15e6);
	}

	/// @dev 3-pick bet where all 3 events are voided. remaining_picks = 0 < min_picks_count (3),
	/// so the bet is refunded. This is an edge case where no events resolved at all.
	function test_settleBet_allVoided_refunds() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// All 3 voided → remaining=0 < min_picks(3) → refund
		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(0);
		outcomes[1] = bytes12(0);
		outcomes[2] = bytes12(0);
		_settleAllMarkets(picks, outcomes);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 2); // STATUS_REFUNDED
	}

	// ─── Settle Bet: Credit Token ───

	function _placeCreditBet()
		internal
		returns (uint256 betId, FlexComboMachine.Pick[] memory picks)
	{
		creditToken.mint(bettor, 100e18);
		vm.prank(bettor);
		creditToken.approve(address(treasury), type(uint256).max);
		creditToken.mint(address(treasury), 100e18);

		uint96[] memory mids = new uint96[](3);
		mids[0] = 11;
		mids[1] = 12;
		mids[2] = 13;
		uint96[] memory oids = new uint96[](3);
		oids[0] = 100;
		oids[1] = 200;
		oids[2] = 300;
		(
			FlexComboMachine.Pick[] memory p,
			FlexComboMachine.LazyCreateEventMarket[] memory lazys
		) = _picks(mids, oids);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = flex.wallet_nonce(bettor);

		flex.placeBet(
			FlexComboMachine.PlaceBetParams({
				picks: p,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 1,
				automated_authority_signature: _signPlaceBet(
					p,
					lazys,
					betSize,
					0,
					bettor,
					deadline,
					nonce,
					1,
					authorityPk
				),
				owner_signature: _signPlaceBet(p, lazys, betSize, 0, bettor, deadline, nonce, 1, bettorPk)
			})
		);
		return (flex.getTotalBetsCount() - 1, p);
	}

	/// @dev Places a bet using credit tokens (token_type=1) and settles as all wins.
	/// Credit tokens are burned from treasury on settlement (regardless of win/loss).
	/// The payout is ALWAYS in regular tokens (USDC), not credit tokens.
	/// Bet: 10 credit tokens → all 3 wins → 30 USDC payout in regular tokens.
	function test_settleBet_creditToken_burnsAndPaysRegular() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks) = _placeCreditBet();

		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100));
		outcomes[1] = bytes12(uint96(200));
		outcomes[2] = bytes12(uint96(300));
		_settleAllMarkets(picks, outcomes);

		uint256 bettorUsdcBefore = usdc.balanceOf(bettor);
		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// Credit tokens burned, payout in regular USDC: 10 * 3.00 = 30 USDC
		assertEq(usdc.balanceOf(bettor), bettorUsdcBefore + 30e6);
	}

	// ─── Settle Bet: Reverts ───

	/// @dev Verifies that settling a bet reverts when not all event markets have been resolved.
	/// Only market #1 is settled; market #2 and #3 are still pending. The contract loops through
	/// all picks and breaks early when it finds an unsettled market, then reverts with EventMarketsNotSettled.
	function test_settleBet_revertsIfNotAllSettled() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// Only settle one market
		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);

		vm.expectRevert(FlexComboMachine.EventMarketsNotSettled.selector);
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	/// @dev Verifies that a bet cannot be settled twice. After the first successful settlement
	/// changes status to SETTLED (5), the second call reverts with BetNotActive because
	/// the contract requires status == ACTIVE (0) to proceed with settlement.
	function test_settleBet_revertsIfAlreadySettled() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		bytes12[] memory outcomes = new bytes12[](3);
		outcomes[0] = bytes12(uint96(100));
		outcomes[1] = bytes12(uint96(200));
		outcomes[2] = bytes12(uint96(300));
		_settleAllMarkets(picks, outcomes);

		uint256 deadline = block.timestamp + 1 hours;
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		vm.expectRevert(FlexComboMachine.BetNotActive.selector);
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	/// @dev Verifies that settleBet reverts when the signature_deadline has passed.
	/// This prevents old/stale automated_authority signatures from being replayed after their
	/// intended validity window. Reverts with SignatureExpired.
	function test_settleBet_revertsExpiredSignature() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp - 1;

		vm.expectRevert(FlexComboMachine.SignatureExpired.selector);
		flex.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	// ─── Enforce Bet Status ───

	/// @dev Compliance officer freezes an active bet. Frozen bets cannot be settled until
	/// reactivated. Used for suspicious activity investigation. Status: ACTIVE(0) → FROZEN(1).
	function test_enforceBetStatus_freeze() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 1); // FROZEN

		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 1);
	}

	/// @dev Compliance officer freezes a bet, then reactivates it after investigation clears.
	/// Only frozen bets can be activated — this is the only valid reverse transition.
	/// Status: ACTIVE(0) → FROZEN(1) → ACTIVE(0).
	function test_enforceBetStatus_activateFromFrozen() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 1); // FROZEN

		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 0); // ACTIVE

		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 0);
	}

	/// @dev Compliance officer refunds an active bet — full stake (10 USDC) returned to bettor.
	/// The treasury drains the funds back. Status: ACTIVE(0) → REFUNDED(2). This is a terminal state.
	function test_enforceBetStatus_refund() public {
		(uint256 betId, , ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 2); // REFUNDED

		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 2);
	}

	/// @dev Compliance officer cannot cancel bets — cancel is user-only via cancelBet().
	/// Status 3 (CANCELED) is no longer accepted by enforceBetStatus.
	function test_enforceBetStatus_cancel_revertsInvalidStatus() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		vm.expectRevert(FlexComboMachine.InvalidStatus.selector);
		flex.enforceBetStatus(betId, 3); // CANCELED no longer allowed
	}

	/// @dev Compliance officer seizes a bet — funds stay in treasury (no withdrawal).
	/// Used for confirmed fraud, insider betting, or rule violations.
	/// Status: ACTIVE(0) → SEIZED(4). Terminal state, bettor gets nothing.
	function test_enforceBetStatus_seize() public {
		(uint256 betId, , ) = _placeDefaultBet();

		uint256 treasuryBal = usdc.balanceOf(address(treasury));

		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 4); // SEIZED

		assertEq(usdc.balanceOf(address(treasury)), treasuryBal);
		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 4);
	}

	/// @dev Verifies that only compliance officers can call enforceBetStatus.
	/// A random stranger address reverts with Unauthorized.
	function test_enforceBetStatus_revertsUnauthorized() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(stranger);
		vm.expectRevert(FlexComboMachine.Unauthorized.selector);
		flex.enforceBetStatus(betId, 1);
	}

	/// @dev Verifies that activating an already-active bet reverts with InvalidStatus.
	/// ACTIVE → ACTIVE is not a valid transition; only FROZEN → ACTIVE is allowed.
	function test_enforceBetStatus_revertsInvalidTransition() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		vm.expectRevert(FlexComboMachine.InvalidStatus.selector);
		flex.enforceBetStatus(betId, 0);
	}

	// ─── Enforce Multiplier Config ───

	/// @dev Compliance officer changes a bet's multiplier config from config 0 to config 1.
	/// This allows adjusting payout terms for a bet post-placement (e.g., correcting a config error
	/// or applying a different payout table for regulatory reasons). Only works on active/frozen bets.
	function test_enforceBetMultiplierConfigId() public {
		// Add second config
		uint256[][] memory mults2 = new uint256[][](4);
		mults2[0] = new uint256[](3);
		mults2[1] = new uint256[](4);
		mults2[2] = new uint256[](5);
		mults2[3] = new uint256[](6);
		for (uint i = 0; i < 3; i++) mults2[0][i] = 100;
		for (uint i = 0; i < 4; i++) mults2[1][i] = 100;
		for (uint i = 0; i < 5; i++) mults2[2][i] = 100;
		for (uint i = 0; i < 6; i++) mults2[3][i] = 100;
		vm.prank(contractOwner);
		flex.addMultiplierConfig(mults2);

		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		flex.enforceBetMultiplierConfigId(betId, 1);

		(, , , uint24 configId, , , ) = flex.bets(betId);
		assertEq(configId, 1);
	}

	// ─── Multiplier Config ───

	/// @dev Owner adds a second multiplier config (all values = 200 = x2.00).
	/// The 2D array must have exactly 4 rows (for picks 3-6) with column counts 3,4,5,6 respectively.
	/// After adding, getMultiplierConfigsCount() returns 2.
	function test_addMultiplierConfig() public {
		assertEq(flex.getMultiplierConfigsCount(), 1);

		uint256[][] memory mults = new uint256[][](4);
		mults[0] = new uint256[](3);
		mults[1] = new uint256[](4);
		mults[2] = new uint256[](5);
		mults[3] = new uint256[](6);
		for (uint i = 0; i < 3; i++) mults[0][i] = 200;
		for (uint i = 0; i < 4; i++) mults[1][i] = 200;
		for (uint i = 0; i < 5; i++) mults[2][i] = 200;
		for (uint i = 0; i < 6; i++) mults[3][i] = 200;

		vm.prank(contractOwner);
		flex.addMultiplierConfig(mults);

		assertEq(flex.getMultiplierConfigsCount(), 2);
	}

	/// @dev Verifies that providing only 2 rows (instead of the required 4 for picks 3-6)
	/// reverts with InvalidMultiplierArrayLength. Row count = max_picks - min_picks + 1 = 6 - 3 + 1 = 4.
	function test_addMultiplierConfig_revertsWrongRowCount() public {
		// Only 2 rows, need 4 (for picks 3-6)
		uint256[][] memory mults = new uint256[][](2);
		mults[0] = new uint256[](3);
		mults[1] = new uint256[](4);
		for (uint i = 0; i < 3; i++) mults[0][i] = 200;
		for (uint i = 0; i < 4; i++) mults[1][i] = 200;

		vm.prank(contractOwner);
		vm.expectRevert(FlexComboMachine.InvalidMultiplierArrayLength.selector);
		flex.addMultiplierConfig(mults);
	}

	/// @dev Verifies that row 0 (for 3 picks) must have exactly 3 columns.
	/// Providing 2 columns reverts with InvalidMultiplierArrayLength.
	/// Each row i must have (min_picks_count + i) columns to cover all possible lost_count values.
	function test_addMultiplierConfig_revertsWrongColumnCount() public {
		// Row 0 should have 3 columns (min_picks=3), give it 2
		uint256[][] memory mults = new uint256[][](4);
		mults[0] = new uint256[](2); // wrong! should be 3
		mults[1] = new uint256[](4);
		mults[2] = new uint256[](5);
		mults[3] = new uint256[](6);
		for (uint i = 0; i < 2; i++) mults[0][i] = 200;
		for (uint i = 0; i < 4; i++) mults[1][i] = 200;
		for (uint i = 0; i < 5; i++) mults[2][i] = 200;
		for (uint i = 0; i < 6; i++) mults[3][i] = 200;

		vm.prank(contractOwner);
		vm.expectRevert(FlexComboMachine.InvalidMultiplierArrayLength.selector);
		flex.addMultiplierConfig(mults);
	}

	/// @dev Verifies that any multiplier value exceeding max_multiplier (25000 = x250.00)
	/// reverts with InvalidMultiplier. This prevents accidentally setting astronomical payouts.
	function test_addMultiplierConfig_revertsExceedsMax() public {
		uint256[][] memory mults = new uint256[][](4);
		mults[0] = new uint256[](3);
		mults[1] = new uint256[](4);
		mults[2] = new uint256[](5);
		mults[3] = new uint256[](6);
		mults[0][0] = MAX_MULTIPLIER + 1; // exceeds max
		mults[0][1] = 100;
		mults[0][2] = 0;
		for (uint i = 0; i < 4; i++) mults[1][i] = 100;
		for (uint i = 0; i < 5; i++) mults[2][i] = 100;
		for (uint i = 0; i < 6; i++) mults[3][i] = 100;

		vm.prank(contractOwner);
		vm.expectRevert(FlexComboMachine.InvalidMultiplier.selector);
		flex.addMultiplierConfig(mults);
	}

	/// @dev Owner updates existing config 0 with new multiplier values (all 200) and deactivates it.
	/// Deactivated configs cannot be used for new bets but existing bets using this config
	/// can still be settled. Verifies is_active is set to false.
	function test_updateMultiplierConfig() public {
		uint256[][] memory mults = new uint256[][](4);
		mults[0] = new uint256[](3);
		mults[1] = new uint256[](4);
		mults[2] = new uint256[](5);
		mults[3] = new uint256[](6);
		for (uint i = 0; i < 3; i++) mults[0][i] = 200;
		for (uint i = 0; i < 4; i++) mults[1][i] = 200;
		for (uint i = 0; i < 5; i++) mults[2][i] = 200;
		for (uint i = 0; i < 6; i++) mults[3][i] = 200;

		vm.prank(contractOwner);
		flex.updateMultiplierConfig(0, mults, false);

		bool isActive = flex.multipliers(0);
		assertFalse(isActive);
	}

	// ─── Configuration ───

	/// @dev Owner updates all configuration parameters at once: new automated_authority address,
	/// new min_bet_size (5 tokens), and new max_bet_size (50,000 tokens).
	/// Non-zero values are applied; zero values are skipped (see test_updateConfiguration_skipsZeros).
	function test_updateConfiguration() public {
		address newAuth = makeAddr("newAuth");

		vm.prank(contractOwner);
		flex.updateConfiguration(newAuth, address(0), 5e18, 50_000e18, type(uint16).max);

		assertEq(flex.automated_authority_address(), newAuth);
		(uint128 minBet, uint128 maxBet) = flex.bet_limits();
		assertEq(minBet, 5e18);
		assertEq(maxBet, 50_000e18);
	}

	/// @dev Verifies that passing address(0) and 0 values to updateConfiguration skips those fields.
	/// This allows updating only specific parameters without affecting others.
	function test_updateConfiguration_skipsZeros() public {
		vm.prank(contractOwner);
		flex.updateConfiguration(address(0), address(0), 0, 0, type(uint16).max);

		assertEq(flex.automated_authority_address(), authority);
		(uint128 minBet, uint128 maxBet) = flex.bet_limits();
		assertEq(minBet, 1000000000000000);
		assertEq(maxBet, 100_000e18);
	}

	/// @dev Verifies that a non-owner cannot call updateConfiguration.
	/// Reverts with OwnableUnauthorizedAccount(stranger).
	function test_updateConfiguration_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(
			abi.encodeWithSelector(FlexComboMachine.OwnableUnauthorizedAccount.selector, stranger)
		);
		flex.updateConfiguration(makeAddr("x"), address(0), 0, 0, type(uint16).max);
	}

	// ─── Compliance Officers ───

	/// @dev Owner adds a new compliance officer, verifies they're registered, then removes them.
	/// Compliance officers can enforce bet statuses, manage blacklists, and change multiplier configs.
	function test_addRemoveComplianceOfficer() public {
		address officer = makeAddr("newOfficer");

		vm.prank(contractOwner);
		flex.addComplianceOfficer(officer);
		assertTrue(flex.compliance_officers(officer));

		vm.prank(contractOwner);
		flex.removeComplianceOfficer(officer);
		assertFalse(flex.compliance_officers(officer));
	}

	// ─── Blacklist ───

	/// @dev Compliance officer adds a wallet to the blacklist, verifies it's blocked,
	/// then removes it. Blacklisted wallets cannot place new bets but existing bets are unaffected.
	function test_addRemoveBlacklist() public {
		address wallet = makeAddr("target");

		vm.prank(complianceOfficer);
		flex.addToBlacklist(wallet);
		assertTrue(flex.blacklisted_wallets(wallet));

		vm.prank(complianceOfficer);
		flex.removeFromBlacklist(wallet);
		assertFalse(flex.blacklisted_wallets(wallet));
	}

	// ─── Pause ───

	/// @dev Owner pauses the contract (blocking placeBet and settleBet), then unpauses.
	/// After unpausing, a bet can be placed normally, confirming the contract is fully operational again.
	function test_pause_unpause() public {
		vm.prank(contractOwner);
		flex.pause();

		vm.prank(contractOwner);
		flex.unpause();

		_placeDefaultBet();
		assertEq(flex.getTotalBetsCount(), 1);
	}

	// ─── Ownership ───

	/// @dev Verifies that ownership can be transferred to a new address.
	/// The new owner gains all onlyOwner privileges (config, pause, multipliers, compliance).
	function test_transferOwnership() public {
		address newOwner = makeAddr("newOwner");
		vm.prank(contractOwner);
		flex.transferOwnership(newOwner);
		assertEq(flex.owner(), newOwner);
	}

	/// @dev Verifies that ownership can be renounced (set to address(0)).
	/// After renouncing, no one can call onlyOwner functions — this is irreversible.
	function test_renounceOwnership() public {
		vm.prank(contractOwner);
		flex.renounceOwnership();
		assertEq(flex.owner(), address(0));
	}

	// ─── Cancel Bet ───

	function _createCancelParams(
		uint256 betId,
		FlexComboMachine.Pick[] memory picks,
		address owner_,
		uint256 ownerPk,
		uint256 deadline
	) internal view returns (FlexComboMachine.CancelBetParams memory) {
		uint256 nonce = flex.wallet_nonce(owner_);
		bytes memory ownerSig = _signCancelBet(owner_, betId, picks, deadline, nonce, ownerPk);
		bytes memory authSig = _signCancelBet(owner_, betId, picks, deadline, nonce, authorityPk);
		return FlexComboMachine.CancelBetParams({
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
		FlexComboMachine.Pick[] memory picks,
		address owner_,
		uint256 ownerPk
	) internal {
		FlexComboMachine.CancelBetParams memory params = _createCancelParams(
			betId, picks, owner_, ownerPk, block.timestamp + 1 hours
		);
		flex.cancelBet(params);
	}

	/// @dev User cancels active bet before settlement window, receives 90% refund (10% fee)
	function test_cancelBet_success() public {
		// Set 10% cancel fee (1000 bps)
		vm.prank(contractOwner);
		flex.updateConfiguration(address(0), address(0), 0, 0, 1000);

		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		_cancelBetWithSigs(betId, picks, bettor, bettorPk);

		// 10 USDC bet, 10% fee = 1 USDC fee, 9 USDC refund (9e6 in USDC decimals)
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 9e6);

		(, uint8 status, , , , , ) = flex.bets(betId);
		assertEq(status, 3); // STATUS_CANCELED
	}

	/// @dev Cancel with 0% fee returns full amount
	function test_cancelBet_zeroFee() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		_cancelBetWithSigs(betId, picks, bettor, bettorPk);

		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
	}

	/// @dev Cancel reverts after settlement window opens
	function test_cancelBet_revertsCancelWindowClosed() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 3 hours;
		FlexComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, deadline);

		// Warp past min_settlement_ts but before deadline
		vm.warp(block.timestamp + 2 hours);

		vm.expectRevert(FlexComboMachine.CancelWindowClosed.selector);
		flex.cancelBet(params);
	}

	/// @dev Cancel reverts with invalid owner signature
	function test_cancelBet_revertsInvalidOwnerSignature() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = flex.wallet_nonce(bettor);
		uint256 strangerPk = 0x5678;
		bytes memory ownerSig = _signCancelBet(bettor, betId, picks, deadline, nonce, strangerPk);
		bytes memory authSig = _signCancelBet(bettor, betId, picks, deadline, nonce, authorityPk);

		vm.expectRevert(FlexComboMachine.InvalidSignature.selector);
		flex.cancelBet(FlexComboMachine.CancelBetParams({
			bet_id: betId, picks: picks, bet_owner: bettor, deadline: deadline,
			owner_signature: ownerSig, automated_authority_signature: authSig
		}));
	}

	/// @dev Cancel reverts with invalid authority signature
	function test_cancelBet_revertsInvalidAuthoritySignature() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = flex.wallet_nonce(bettor);
		bytes memory ownerSig = _signCancelBet(bettor, betId, picks, deadline, nonce, bettorPk);
		uint256 fakePk = 0x9999;
		bytes memory authSig = _signCancelBet(bettor, betId, picks, deadline, nonce, fakePk);

		vm.expectRevert(FlexComboMachine.InvalidSignature.selector);
		flex.cancelBet(FlexComboMachine.CancelBetParams({
			bet_id: betId, picks: picks, bet_owner: bettor, deadline: deadline,
			owner_signature: ownerSig, automated_authority_signature: authSig
		}));
	}

	/// @dev Cancel reverts when bet_owner doesn't match actual bet owner
	function test_cancelBet_revertsNonOwner() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 strangerPk = 0x5678;
		address strangerAddr = vm.addr(strangerPk);

		FlexComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, strangerAddr, strangerPk, block.timestamp + 1 hours);

		vm.expectRevert(FlexComboMachine.Unauthorized.selector);
		flex.cancelBet(params);
	}

	/// @dev Cannot cancel non-active bet
	function test_cancelBet_revertsNotActive() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// Freeze the bet first
		vm.prank(complianceOfficer);
		flex.enforceBetStatus(betId, 1); // FROZEN

		FlexComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, block.timestamp + 1 hours);

		vm.expectRevert(FlexComboMachine.BetNotActive.selector);
		flex.cancelBet(params);
	}

	/// @dev Cancel reverts with wrong picks
	function test_cancelBet_revertsInvalidPicks() public {
		(uint256 betId, , ) = _placeDefaultBet();

		FlexComboMachine.Pick[] memory wrongPicks = new FlexComboMachine.Pick[](3);
		wrongPicks[0] = FlexComboMachine.Pick({
			event_market_id: bytes12(uint96(1)),
			outcome_id: bytes12(uint96(999))
		});
		wrongPicks[1] = FlexComboMachine.Pick({
			event_market_id: bytes12(uint96(2)),
			outcome_id: bytes12(uint96(999))
		});
		wrongPicks[2] = FlexComboMachine.Pick({
			event_market_id: bytes12(uint96(3)),
			outcome_id: bytes12(uint96(999))
		});

		FlexComboMachine.CancelBetParams memory params = _createCancelParams(betId, wrongPicks, bettor, bettorPk, block.timestamp + 1 hours);

		vm.expectRevert(FlexComboMachine.InvalidInput.selector);
		flex.cancelBet(params);
	}

	/// @dev Cancel reverts when deadline has passed
	function test_cancelBet_revertsExpiredDeadline() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		FlexComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, deadline);

		// Warp past deadline
		vm.warp(deadline + 1);

		vm.expectRevert(FlexComboMachine.SignatureExpired.selector);
		flex.cancelBet(params);
	}

	/// @dev Cancel increments wallet nonce
	function test_cancelBet_incrementsNonce() public {
		(uint256 betId, FlexComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 nonceBefore = flex.wallet_nonce(bettor);
		_cancelBetWithSigs(betId, picks, bettor, bettorPk);
		assertEq(flex.wallet_nonce(bettor), nonceBefore + 1);
	}

	/// @dev Cancel fee bps can be updated via updateConfiguration
	function test_cancelFeeBps_updateConfiguration() public {
		vm.prank(contractOwner);
		flex.updateConfiguration(address(0), address(0), 0, 0, 500); // 5%

		assertEq(flex.cancel_fee_bps(), 500);

		// Skip update with type(uint16).max
		vm.prank(contractOwner);
		flex.updateConfiguration(address(0), address(0), 0, 0, type(uint16).max);

		assertEq(flex.cancel_fee_bps(), 500); // unchanged
	}

	// ─── Emergency Withdraw ───

	/// @dev Verifies that the owner can withdraw ERC20 tokens accidentally sent to the contract.
	/// This is a safety mechanism — all bet funds are held in the treasury, not in FlexComboMachine.
	/// Any tokens in the contract itself are stuck and can be recovered with this function.
	function test_emergencyWithdrawErc20() public {
		usdc.mint(address(flex), 100e6);

		vm.prank(contractOwner);
		flex.emergencyWithdrawErc20(address(usdc), 100e6);

		assertEq(usdc.balanceOf(contractOwner), 100e6);
	}
}
