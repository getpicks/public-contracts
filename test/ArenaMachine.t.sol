// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ArenaMachine} from "../src/ArenaMachine.sol";
import {EntryVault} from "../src/EntryVault.sol";
import {PrizeTreasury} from "../src/PrizeTreasury.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {IEventMarketRegistry} from "../src/IEventMarketRegistry.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
	ITransparentUpgradeableProxy,
	TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// ─── Mocks ───

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
	mapping(address => bool) public whitelisted_addresses;

	constructor() ERC20("Credit", "CRED") {}

	function setWhitelisted(address account, bool is_whitelisted) external {
		whitelisted_addresses[account] = is_whitelisted;
	}

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

contract MockEventMarketRegistry is IEventMarketRegistry {
	mapping(bytes12 => EventMarket) internal markets;
	bool public is_writer_authorized = true;

	function setWriterAuthorized(bool value) external {
		is_writer_authorized = value;
	}

	function ensureExists(bytes12 event_market_id) external {
		require(is_writer_authorized, "Unauthorized");
		markets[event_market_id].is_exists = true;
	}

	function getEventMarket(bytes12 event_market_id) external view returns (EventMarket memory) {
		return markets[event_market_id];
	}

	function setSettled(bytes12 event_market_id, bytes12 winning_outcome_id) external {
		markets[event_market_id] =
			EventMarket({is_exists: true, is_settled: true, _reserved: 0, winning_outcome_id: winning_outcome_id});
	}
}

// ─── Test ───

contract ArenaMachineTest is Test {
	using MessageHashUtils for bytes32;

	ArenaMachine internal arena;
	address internal arena_proxy_admin;
	EntryVault internal entry;
	PrizeTreasury internal prize;
	EntryVault internal creditEntry;
	PrizeTreasury internal creditPrize;
	VaultFactory internal vault_factory;
	MockEventMarketRegistry internal registry;
	MockUSDC internal coin;
	MockCreditToken internal credit;

	address internal owner = makeAddr("owner");
	address internal creditSink = makeAddr("creditSink"); // stands in for the CreditTokenVault
	uint256 internal authorityPk = 0xA11CE;
	address internal authority;

	uint256 internal u1Pk = 0x1111;
	uint256 internal u2Pk = 0x2222;
	uint256 internal u3Pk = 0x3333;
	uint256 internal u4Pk = 0x4444;
	address internal u1;
	address internal u2;
	address internal u3;
	address internal u4;

	// typehashes (mirror the contract)
	bytes32 internal constant PLACE_USER_TH = keccak256("arenaPlaceLineupUser");
	bytes32 internal constant PLACE_AUTH_TH = keccak256("arenaPlaceLineupAuthority");
	bytes32 internal constant ASSIGN_TH = keccak256("arenaAssignGroup");
	bytes32 internal constant SETTLE_LINEUP_TH = keccak256("arenaSettleLineup");
	bytes32 internal constant SETTLE_GROUP_TH = keccak256("arenaSettleGroup");
	bytes32 internal constant CANCEL_TH = keccak256("arenaCancelLineup");
	bytes32 internal constant REFUND_GROUP_TH = keccak256("arenaRefundGroup");
	bytes32 internal constant REASON_HASH = keccak256("arena-test-refund-reason-longer-than-thirty-two-bytes");

	// outcomes / statuses (mirror the contract)
	uint8 internal constant OUTCOME_LOST = 0;
	uint8 internal constant OUTCOME_WIN = 1;
	uint8 internal constant STATUS_SETTLED = 2;
	uint8 internal constant STATUS_REFUNDED = 3;

	uint8 internal constant TOKEN_COIN = 0;
	uint8 internal constant TOKEN_CREDIT = 1;
	uint8 internal constant TOKEN_CREDIT_PRIZE = 2;

	bytes12 internal constant M1 = bytes12(uint96(0x1001));
	bytes12 internal constant M2 = bytes12(uint96(0x1002));
	bytes12 internal constant M3 = bytes12(uint96(0x1003));
	bytes12 internal constant WIN1 = bytes12(uint96(0xAA01));
	bytes12 internal constant WIN2 = bytes12(uint96(0xAA02));
	bytes12 internal constant WIN3 = bytes12(uint96(0xAA03));
	bytes32 internal constant GROUP = bytes32(uint256(0xABCDEF));
	bytes32 internal constant PICKS_COMMITMENT_TYPEHASH = keccak256("picksCommitment");
	bytes32 internal constant SALT = keccak256("arena-test-salt");

	uint128 internal constant ENTRY_COIN = 10e18; // $10 internal (18 dec)
	uint128 internal constant ENTRY_CREDIT = 5e18; // $5 coupon
	uint32 internal constant LINEUP_MULT = 300; // 3x base

	function setUp() public {
		authority = vm.addr(authorityPk);
		u1 = vm.addr(u1Pk);
		u2 = vm.addr(u2Pk);
		u3 = vm.addr(u3Pk);
		u4 = vm.addr(u4Pk);

		coin = new MockUSDC();
		credit = new MockCreditToken();
		registry = new MockEventMarketRegistry();

		vm.startPrank(owner);
		vault_factory = new VaultFactory(owner);
		(, address entry_addr, address prize_addr) = vault_factory.createVaultPair(); // id 0: coin prize
		(, address credit_entry_addr, address credit_prize_addr) = vault_factory.createVaultPair(); // id 1: credit prize
		entry = EntryVault(payable(entry_addr));
		prize = PrizeTreasury(payable(prize_addr));
		creditEntry = EntryVault(payable(credit_entry_addr));
		creditPrize = PrizeTreasury(payable(credit_prize_addr));
		entry.setTokenPolicy(address(coin), true, 0, 0);
		entry.setTokenPolicy(address(credit), true, 0, 0);
		prize.setTokenPolicy(address(coin), true, 0, 0);
		creditEntry.setTokenPolicy(address(credit), true, 0, 0);
		creditPrize.setTokenPolicy(address(credit), true, 0, 0);

		arena = _deployArena(address(coin));
		arena_proxy_admin = _readProxyAdmin(address(arena));

		entry.addToWhitelist(address(arena));
		prize.addToWhitelist(address(arena));
		creditEntry.addToWhitelist(address(arena));
		creditPrize.addToWhitelist(address(arena));
		credit.setWhitelisted(address(entry), true);
		credit.setWhitelisted(address(creditEntry), true);
		credit.setWhitelisted(address(creditPrize), true);
		arena.setTokenTypeVaultPair(TOKEN_COIN, 0);
		arena.setTokenTypeVaultPair(TOKEN_CREDIT, 0);
		arena.setTokenTypeVaultPair(TOKEN_CREDIT_PRIZE, 1);
		arena.setCreditRecycleAddress(creditSink);

		// caps must be set (0 = nothing allowed / fail-safe)
		arena.setMaxMultiplierCap(100000000);
		arena.setMaxGroupSize(16);
		vm.stopPrank();

		// fund the prize treasury with company capital
		coin.mint(owner, 1_000_000e6);
		vm.startPrank(owner);
		coin.approve(address(prize), type(uint256).max);
		prize.fund(address(coin), 500_000e6);
		credit.mint(owner, 1_000_000e18);
		credit.approve(address(creditPrize), type(uint256).max);
		creditPrize.fund(address(credit), 500_000e18);
		vm.stopPrank();

		// fund + approve users
		address[4] memory users = [u1, u2, u3, u4];
		for (uint256 i = 0; i < users.length; i++) {
			coin.mint(users[i], 1000e6);
			credit.mint(users[i], 100e18);
			vm.startPrank(users[i]);
			coin.approve(address(entry), type(uint256).max);
			credit.approve(address(entry), type(uint256).max);
			credit.approve(address(creditEntry), type(uint256).max);
			vm.stopPrank();
		}
	}

	// ─── helpers ───

	function _picks() internal pure returns (ArenaMachine.Pick[] memory picks) {
		picks = new ArenaMachine.Pick[](2);
		picks[0] = ArenaMachine.Pick({event_market_id: M1, outcome_id: bytes12(uint96(1)), _reserved: bytes8(0)});
		picks[1] = ArenaMachine.Pick({event_market_id: M2, outcome_id: bytes12(uint96(1)), _reserved: bytes8(0)});
	}

	function _threePicks() internal pure returns (ArenaMachine.Pick[] memory picks) {
		picks = new ArenaMachine.Pick[](3);
		picks[0] = ArenaMachine.Pick({event_market_id: M1, outcome_id: bytes12(uint96(1)), _reserved: bytes8(0)});
		picks[1] = ArenaMachine.Pick({event_market_id: M2, outcome_id: bytes12(uint96(1)), _reserved: bytes8(0)});
		picks[2] = ArenaMachine.Pick({event_market_id: M3, outcome_id: bytes12(uint96(1)), _reserved: bytes8(0)});
	}

	function _settleMarkets() internal {
		registry.setSettled(M1, WIN1);
		registry.setSettled(M2, WIN2);
		registry.setSettled(M3, WIN3);
	}

	function _picksHash(address lineupOwner, ArenaMachine.Pick[] memory picks, bytes32 salt)
		internal
		view
		returns (bytes32)
	{
		return keccak256(abi.encode(PICKS_COMMITMENT_TYPEHASH, block.chainid, address(arena), lineupOwner, picks, salt));
	}

	function _signPlaceUser(ArenaMachine.PlaceLineupParams memory p, uint256 nonce, uint256 pk)
		internal
		view
		returns (bytes memory)
	{
		bytes32 h = keccak256(
				abi.encode(
					PLACE_USER_TH,
					block.chainid,
					address(arena),
					p.picks_hash,
					p.size,
					p.token_type,
					p.owner_address,
					nonce,
					p.deadline
				)
			).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
		return abi.encodePacked(r, s, v);
	}

	function _signPlaceAuthority(ArenaMachine.PlaceLineupParams memory p) internal view returns (bytes memory) {
		bytes32 h = keccak256(
				abi.encode(
					PLACE_AUTH_TH,
					block.chainid,
					address(arena),
					p.picks_hash,
					p.size,
					p.token_type,
					p.vault_pair_id,
					p.max_multiplier,
					p.owner_address,
					p.deadline
				)
			).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, h);
		return abi.encodePacked(r, s, v);
	}

	function _buildPlace(uint256 pk, ArenaMachine.Pick[] memory picks, uint128 size, uint8 tokenType)
		internal
		view
		returns (ArenaMachine.PlaceLineupParams memory p)
	{
		address user = vm.addr(pk);
		p = ArenaMachine.PlaceLineupParams({
			picks_hash: _picksHash(user, picks, SALT),
			size: size,
			token_type: tokenType,
			vault_pair_id: tokenType == TOKEN_CREDIT_PRIZE ? 1 : 0,
			max_multiplier: LINEUP_MULT,
			owner_address: user,
			deadline: block.timestamp + 1 hours,
			owner_signature: "",
			automated_authority_signature: ""
		});
		p.owner_signature = _signPlaceUser(p, arena.wallet_nonce(user), pk);
		p.automated_authority_signature = _signPlaceAuthority(p);
	}

	function _place(uint256 pk, ArenaMachine.Pick[] memory picks, uint128 size, uint8 tokenType)
		internal
		returns (uint256 id)
	{
		id = arena.lineupsCount();
		arena.placeLineup(_buildPlace(pk, picks, size, tokenType));
	}

	function _signAssign(bytes32 groupId, uint256[] memory ids, uint256 deadline) internal view returns (bytes memory) {
		bytes32 h = keccak256(abi.encode(ASSIGN_TH, block.chainid, address(arena), groupId, ids, deadline))
			.toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, h);
		return abi.encodePacked(r, s, v);
	}

	function _assign(bytes32 groupId, uint256[] memory ids) internal {
		uint256 dl = block.timestamp + 1 hours;
		arena.assignGroup(groupId, ids, dl, _signAssign(groupId, ids, dl));
	}

	function _signSettleLineup(uint256 id, ArenaMachine.Pick[] memory picks, bytes32 salt, uint256 dl)
		internal
		view
		returns (bytes memory)
	{
		bytes32 h = keccak256(abi.encode(SETTLE_LINEUP_TH, block.chainid, address(arena), id, picks, salt, dl))
			.toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, h);
		return abi.encodePacked(r, s, v);
	}

	function _buildSettleLineup(uint256 id, ArenaMachine.Pick[] memory picks)
		internal
		view
		returns (ArenaMachine.SettleLineupParams memory p)
	{
		uint256 dl = block.timestamp + 1 hours;
		p = ArenaMachine.SettleLineupParams({
			lineup_id: id,
			picks: picks,
			salt: SALT,
			deadline: dl,
			automated_authority_signature: _signSettleLineup(id, picks, SALT, dl)
		});
	}

	function _settleLineup(uint256 id, ArenaMachine.Pick[] memory picks) internal {
		arena.settleLineup(_buildSettleLineup(id, picks));
	}

	function _signSettleGroup(ArenaMachine.SettleGroupParams memory p) internal view returns (bytes memory) {
		bytes32 h = keccak256(
				abi.encode(
					SETTLE_GROUP_TH,
					block.chainid,
					address(arena),
					p.group_id,
					p.member_lineup_ids,
					p.amounts,
					p.outcomes,
					p.deadline
				)
			).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, h);
		return abi.encodePacked(r, s, v);
	}

	function _buildSettleGroup(bytes32 groupId, uint256[] memory ids, uint128[] memory amounts, uint8[] memory outcomes)
		internal
		view
		returns (ArenaMachine.SettleGroupParams memory p)
	{
		p = ArenaMachine.SettleGroupParams({
			group_id: groupId,
			member_lineup_ids: ids,
			amounts: amounts,
			outcomes: outcomes,
			deadline: block.timestamp + 1 hours,
			automated_authority_signature: ""
		});
		p.automated_authority_signature = _signSettleGroup(p);
	}

	function _settleGroup(bytes32 groupId, uint256[] memory ids, uint128[] memory amounts, uint8[] memory outcomes)
		internal
	{
		arena.settleGroup(_buildSettleGroup(groupId, ids, amounts, outcomes));
	}

	function _ids4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory ids) {
		ids = new uint256[](4);
		ids[0] = a;
		ids[1] = b;
		ids[2] = c;
		ids[3] = d;
	}

	function _refundAmount(uint256 lineup_id) internal view returns (uint128) {
		ArenaMachine.Lineup memory lineup = arena.getLineup(lineup_id);
		if (lineup.status == STATUS_REFUNDED) {
			return 0;
		}
		return lineup.token_type == 0 ? uint128(uint256(lineup.size) / 1e12) : lineup.size;
	}

	function _groupRefundAmounts(uint256[] memory ids) internal view returns (uint128[] memory amounts) {
		amounts = new uint128[](ids.length);
		for (uint256 i = 0; i < ids.length; ++i) {
			amounts[i] = _refundAmount(ids[i]);
		}
	}

	function _signRefundGroup(bytes32 groupId, uint256[] memory ids, uint256 deadline)
		internal
		view
		returns (bytes memory)
	{
		bytes32 h = keccak256(
			abi.encode(REFUND_GROUP_TH, block.chainid, address(arena), groupId, ids, _groupRefundAmounts(ids), REASON_HASH, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, h);
		return abi.encodePacked(r, s, v);
	}

	function _refundGroup(bytes32 groupId, uint256[] memory ids, uint256 deadline) internal {
		arena.refundGroup(groupId, ids, _groupRefundAmounts(ids), REASON_HASH, deadline, _signRefundGroup(groupId, ids, deadline));
	}

	function _buildCancel(uint256 lineupId, uint256 userPk)
		internal
		view
		returns (ArenaMachine.CancelLineupParams memory p)
	{
		address user = vm.addr(userPk);
		uint256 dl = block.timestamp + 1 hours;
		bytes32 h = keccak256(abi.encode(CANCEL_TH, block.chainid, address(arena), lineupId, user, dl))
			.toEthSignedMessageHash();
		(uint8 userV, bytes32 userR, bytes32 userS) = vm.sign(userPk, h);
		(uint8 authorityV, bytes32 authorityR, bytes32 authorityS) = vm.sign(authorityPk, h);
		p = ArenaMachine.CancelLineupParams({
			lineup_id: lineupId,
			owner_address: user,
			deadline: dl,
			owner_signature: abi.encodePacked(userR, userS, userV),
			automated_authority_signature: abi.encodePacked(authorityR, authorityS, authorityV)
		});
	}

	// ─── placement ───

	function test_placeLineup_pullsEntryAndStores() public {
		uint256 id = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);

		assertEq(id, 0);
		assertEq(coin.balanceOf(u1), 990e6); // pulled $10
		assertEq(coin.balanceOf(address(entry)), 10e6);
		ArenaMachine.Lineup memory l = arena.getLineup(0);
		assertEq(l.owner, u1);
		assertEq(uint256(l.max_multiplier), 300); // 3x base * 1.00 * 1.00
		assertEq(arena.wallet_nonce(u1), 1);
	}

	function test_placeLineup_type2PullsCreditIntoCreditPrizePair() public {
		uint256 id = _place(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT_PRIZE);

		ArenaMachine.Lineup memory lineup = arena.getLineup(id);
		assertEq(lineup.token_type, TOKEN_CREDIT_PRIZE);
		assertEq(lineup.vault_pair_id, 1);
		assertEq(credit.balanceOf(u1), 95e18);
		assertEq(credit.balanceOf(address(creditEntry)), 5e18);
		assertEq(credit.balanceOf(address(entry)), 0);
	}

	function test_placeLineup_rejectsWrongPairForTokenType() public {
		ArenaMachine.PlaceLineupParams memory params = _buildPlace(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT_PRIZE);
		params.vault_pair_id = 0;
		params.owner_signature = _signPlaceUser(params, arena.wallet_nonce(u1), u1Pk);
		params.automated_authority_signature = _signPlaceAuthority(params);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.placeLineup(params);
	}

	function test_setTokenTypeVaultPair_rejectsUnsupportedType() public {
		vm.prank(owner);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.setTokenTypeVaultPair(3, 1);
	}

	function test_setTokenTypeVaultPair_rejectsCreditPrizeOnCoinPair() public {
		vm.prank(owner);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.setTokenTypeVaultPair(TOKEN_CREDIT_PRIZE, 0);
	}

	function test_placeLineup_revertsOnTamperedCommitment() public {
		ArenaMachine.PlaceLineupParams memory p = _buildPlace(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		p.picks_hash = keccak256("tampered");
		vm.expectRevert(ArenaMachine.InvalidSignature.selector);
		arena.placeLineup(p);
	}

	function test_placeLineup_revertsOnMultiplierAboveCap() public {
		ArenaMachine.PlaceLineupParams memory p = _buildPlace(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		p.max_multiplier = 100000001;
		p.owner_signature = _signPlaceUser(p, arena.wallet_nonce(u1), u1Pk);
		p.automated_authority_signature = _signPlaceAuthority(p);
		vm.expectRevert(ArenaMachine.MultiplierExceedsCap.selector);
		arena.placeLineup(p);
	}

	function test_caps_zeroMeansNothingAllowed() public {
		vm.prank(owner);
		arena.setMaxMultiplierCap(0); // fail-safe: 0 => nothing passes
		ArenaMachine.PlaceLineupParams memory p = _buildPlace(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		vm.expectRevert(ArenaMachine.MultiplierExceedsCap.selector);
		arena.placeLineup(p);
	}

	// ─── grouping ───

	function test_assignGroup_linksMembers() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		_assign(GROUP, _ids4(a, b, c, d));

		assertEq(arena.getLineup(a).group_id, GROUP);
		ArenaMachine.Group memory g = arena.getGroup(GROUP);
		assertEq(uint256(g.member_count), 4);
	}

	/// Minimum group size is an off-chain product rule, so a small group is accepted here.
	function test_assignGroup_allowsSmallGroupAndRejectsEmpty() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		uint256 dl = block.timestamp + 1 hours;
		arena.assignGroup(GROUP, ids, dl, _signAssign(GROUP, ids, dl));
		assertEq(arena.getGroup(GROUP).member_count, 2);

		uint256[] memory empty_ids = new uint256[](0);
		bytes32 g2 = bytes32(uint256(0xBEEF));
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.assignGroup(g2, empty_ids, dl, _signAssign(g2, empty_ids, dl));
	}

	function test_assignGroup_revertsAboveGlobalMax() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		vm.prank(owner);
		arena.setMaxGroupSize(1);
		vm.expectRevert(ArenaMachine.GroupTooLarge.selector);
		_assign(GROUP, ids);
	}

	function test_pickCountLimits_defaultAndOwnerAdjustable() public {
		assertEq(arena.min_picks_count(), 2);
		assertEq(arena.max_picks_count(), 6);

		vm.prank(owner);
		arena.setPickCountLimits(3, 5);
		assertEq(arena.min_picks_count(), 3);
		assertEq(arena.max_picks_count(), 5);

		vm.prank(u1);
		vm.expectRevert(abi.encodeWithSelector(ArenaMachine.OwnableUnauthorizedAccount.selector, u1));
		arena.setPickCountLimits(2, 6);

		vm.startPrank(owner);
		arena.setPickCountLimits(1, 7);
		assertEq(arena.min_picks_count(), 1);
		assertEq(arena.max_picks_count(), 7);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.setPickCountLimits(0, 6);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.setPickCountLimits(4, 3);
		vm.stopPrank();
	}

	function test_assignGroup_revertsOnDoubleGroup() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		_assign(GROUP, _ids4(a, b, c, d));
		// reuse member `a` in another group -> already grouped
		bytes32 g2 = bytes32(uint256(0xBEEF));
		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		_assign(g2, _ids4(a, b, c, d));
	}

	function test_assignGroup_revertsWhenMemberWasCanceled() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		arena.cancelLineup(_buildCancel(a, u1Pk));

		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		_assign(GROUP, _ids4(a, b, c, d));
	}

	// ─── layer 1 ───

	function test_settleLineup_revertsIfNotGrouped() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		_settleMarkets();
		ArenaMachine.SettleLineupParams memory p = _buildSettleLineup(a, _picks());
		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		arena.settleLineup(p);
	}

	function test_settleLineup_enforcesCurrentPickCountLimits() public {
		uint256 two_pick_lineup = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 three_pick_lineup = _place(u2Pk, _threePicks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = two_pick_lineup;
		ids[1] = three_pick_lineup;
		_assign(GROUP, ids);
		_settleMarkets();

		vm.prank(owner);
		arena.setPickCountLimits(3, 6);
		ArenaMachine.SettleLineupParams memory two_pick_params = _buildSettleLineup(two_pick_lineup, _picks());
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.settleLineup(two_pick_params);

		vm.prank(owner);
		arena.setPickCountLimits(2, 2);
		ArenaMachine.SettleLineupParams memory three_pick_params = _buildSettleLineup(three_pick_lineup, _threePicks());
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.settleLineup(three_pick_params);
	}

	function test_settleLineup_revertsOnWrongSalt() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		_settleMarkets();

		ArenaMachine.SettleLineupParams memory p = _buildSettleLineup(a, _picks());
		p.salt = keccak256("wrong-salt");
		p.automated_authority_signature = _signSettleLineup(a, p.picks, p.salt, p.deadline);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.settleLineup(p);
	}

	function test_settleLineup_logsPicksAndSalt() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		_settleMarkets();

		vm.recordLogs();
		_settleLineup(a, _picks());
		Vm.Log[] memory logs = vm.getRecordedLogs();
		bytes32 event_signature = keccak256("LineupRevealed(uint256,(bytes12,bytes12,bytes8)[],bytes32)");
		bool found;
		for (uint256 i = 0; i < logs.length; ++i) {
			if (logs[i].topics[0] != event_signature) continue;
			(ArenaMachine.Pick[] memory logged_picks, bytes32 logged_salt) =
				abi.decode(logs[i].data, (ArenaMachine.Pick[], bytes32));
			assertEq(logged_picks.length, 2);
			assertEq(logged_picks[0].event_market_id, M1);
			assertEq(logged_salt, SALT);
			found = true;
		}
		assertTrue(found);
	}

	// ─── full happy path ───

	function test_fullHappyPath_place_assign_settle_claim() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		assertEq(uint256(arena.getGroup(GROUP).status), 0); // GROUP_STATUS_ACTIVE

		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		amounts[0] = 20e6; // winner: $20 (<= 3x * $10 = $30)
		outcomes[0] = OUTCOME_WIN;
		outcomes[1] = OUTCOME_LOST;
		outcomes[2] = OUTCOME_LOST;
		_refundRevealedMember(d);

		_settleGroup(GROUP, ids, amounts, outcomes);

		assertEq(uint256(arena.getGroup(GROUP).status), 1); // GROUP_STATUS_SETTLED
		assertEq(uint256(arena.getLineup(a).owed), 20e6);
		assertEq(uint256(arena.getLineup(d).owed), 10e6);
		assertEq(uint256(arena.getLineup(d).status), STATUS_REFUNDED);
		assertEq(uint256(arena.getLineup(b).owed), 0);

		uint256[] memory prize_ids = new uint256[](1);
		prize_ids[0] = a;
		arena.batchClaimPrize(prize_ids);
		_claim(d);

		assertEq(coin.balanceOf(u1), 1010e6); // +$20 prize
		assertEq(coin.balanceOf(u4), 1000e6); // entry refunded
		assertEq(coin.balanceOf(u2), 990e6); // lost, nothing back

		// loser cannot claim, double-claim reverts
		vm.expectRevert(ArenaMachine.NothingToClaim.selector);
		arena.claimPrize(b);
		vm.expectRevert(ArenaMachine.NothingToClaim.selector);
		arena.claimPrize(a);
	}

	function testFuzz_settleGroupRejectsRefundOutcomes(uint8 outcome) public {
		outcome = uint8(bound(outcome, 2, 255));
		uint256[] memory ids = new uint256[](1);
		ids[0] = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(ids[0], _picks());
		uint8[] memory outcomes = new uint8[](1);
		outcomes[0] = outcome;
		ArenaMachine.SettleGroupParams memory params = _buildSettleGroup(GROUP, ids, new uint128[](1), outcomes);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.settleGroup(params);
		assertEq(arena.getGroup(GROUP).status, 0);
		assertEq(arena.getLineup(ids[0]).owed, 0);
	}

	function test_settleGroup_revertsOnPayoutTooHigh() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		amounts[0] = 31e6; // > 3x * $10 = $30
		outcomes[0] = OUTCOME_WIN;
		ArenaMachine.SettleGroupParams memory p = _buildSettleGroup(GROUP, ids, amounts, outcomes);
		vm.expectRevert(ArenaMachine.PayoutTooHigh.selector);
		arena.settleGroup(p);
	}

	// ─── coupons ───

	function test_coupon_consumedCreditAccruesAndRecycles() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT); // coupon, wins
		uint256 b = _place(u2Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT); // coupon, loses
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		assertEq(credit.balanceOf(address(entry)), 10e18); // 2 coupons deposited

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		amounts[0] = 8e6; // coupon win: $8 (<= 3x * $5 = $15), paid in COIN from prize
		outcomes[0] = OUTCOME_WIN;
		outcomes[1] = OUTCOME_LOST;
		outcomes[2] = OUTCOME_LOST;
		_refundRevealedMember(d);
		_settleGroup(GROUP, ids, amounts, outcomes);

		// both coupons consumed (win + lost) -> accrued for batch recycle, not yet moved
		assertEq(arena.pending_credit_recycle(0), 10e18);
		assertEq(credit.balanceOf(address(entry)), 10e18);

		// coupon winner is paid real COIN from the prize treasury
		arena.claimPrize(a);
		assertEq(coin.balanceOf(u1), 1000e6 + 8e6);

		// daily batch recycle moves the consumed credit back to the credit vault (no burn)
		vm.prank(authority);
		arena.recycleConsumedCredit(0);
		assertEq(arena.pending_credit_recycle(0), 0);
		assertEq(credit.balanceOf(address(entry)), 0);
		assertEq(credit.balanceOf(creditSink), 10e18);
	}

	function test_type2WinPaysCreditFromPrizeAndRecyclesEntry() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT_PRIZE);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		amounts[0] = 15e18; // 5 credits * 3x, paid in credit
		outcomes[0] = OUTCOME_WIN;
		outcomes[1] = OUTCOME_LOST;
		outcomes[2] = OUTCOME_LOST;
		outcomes[3] = OUTCOME_LOST;
		_settleGroup(GROUP, ids, amounts, outcomes);

		assertEq(arena.pending_credit_recycle(1), 5e18);
		assertEq(credit.balanceOf(u1), 95e18);
		arena.claimPrize(a);
		assertEq(credit.balanceOf(u1), 110e18);
		assertEq(credit.balanceOf(address(creditPrize)), 500_000e18 - 15e18);

		vm.prank(authority);
		arena.recycleConsumedCredit(1);
		assertEq(credit.balanceOf(address(creditEntry)), 0);
		assertEq(credit.balanceOf(creditSink), 5e18);
	}

	function test_type2WinRevertsAboveCreditDenominatedBound() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT_PRIZE);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());

		uint128[] memory amounts = new uint128[](2);
		uint8[] memory outcomes = new uint8[](2);
		amounts[0] = 15e18 + 1;
		outcomes[0] = OUTCOME_WIN;
		vm.expectRevert(ArenaMachine.PayoutTooHigh.selector);
		_settleGroup(GROUP, ids, amounts, outcomes);
	}

	// ─── refund paths ───

	function test_batchRefund_bindsReasonAndRejectsEmptyReason() public {
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(TOKEN_COIN);
		uint256 deadline = block.timestamp + 100;
		bytes memory signature = _signRefundBatch(params, deadline, block.chainid, address(arena));
		params[0].reason_hash = keccak256("changed-reason");
		vm.expectRevert(ArenaMachine.InvalidSignature.selector);
		arena.batchRefundLineups(params, deadline, signature);
		params[0].reason_hash = bytes32(0);
		signature = _signRefundBatch(params, deadline, block.chainid, address(arena));
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.batchRefundLineups(params, deadline, signature);
		assertEq(arena.getLineup(params[0].lineup_id).status, 0);
	}

	function test_refundGroup_refundsEveryMember() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		uint256 deadline = block.timestamp + 1 hours;

		uint128[] memory amounts = _groupRefundAmounts(ids);
		bytes memory signature = _signRefundGroup(GROUP, ids, deadline);
		vm.expectRevert(ArenaMachine.InvalidSignature.selector);
		arena.refundGroup(GROUP, ids, amounts, keccak256("changed-reason"), deadline, signature);
		vm.expectEmit(true, true, false, true, address(arena));
		emit ArenaMachine.LineupRefunded(a, u1, 10e6, REASON_HASH);
		vm.expectEmit(true, true, false, true, address(arena));
		emit ArenaMachine.LineupRefunded(b, u2, 10e6, REASON_HASH);
		vm.expectEmit(true, false, false, true, address(arena));
		emit ArenaMachine.GroupRefunded(GROUP, REASON_HASH);
		_refundGroup(GROUP, ids, deadline);

		assertEq(uint256(arena.getGroup(GROUP).status), 2); // GROUP_STATUS_REFUNDED
		assertEq(uint256(arena.getLineup(a).status), STATUS_REFUNDED);
		assertEq(uint256(arena.getLineup(a).owed), 10e6);
		assertEq(coin.balanceOf(u1), 990e6);
		_claim(a);
		_claim(b);
		assertEq(uint256(arena.getLineup(a).owed), 0);
		assertEq(coin.balanceOf(u1), 1000e6);
		assertEq(coin.balanceOf(u2), 1000e6);
	}

	function test_refundGroup_revertsWhileMemberIsFrozen() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		vm.prank(authority);
		arena.freezeLineup(a);
		uint256 deadline = block.timestamp + 1 hours;

		uint128[] memory amounts = _groupRefundAmounts(ids);
		bytes memory signature = _signRefundGroup(GROUP, ids, deadline);
		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		arena.refundGroup(GROUP, ids, amounts, REASON_HASH, deadline, signature);
	}

	function test_refundGroup_refundsRevealedMembers() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		uint256 deadline = block.timestamp + 1 hours;
		_refundGroup(GROUP, ids, deadline);
		assertEq(uint256(arena.getLineup(a).owed), 10e6);
		_claim(a);
		_claim(b);
		assertEq(coin.balanceOf(u1), 1000e6);
		assertEq(coin.balanceOf(u2), 1000e6);
	}

	function test_refundGroup_type2ReturnsCreditFromEntryVault() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_CREDIT, TOKEN_CREDIT_PRIZE);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = new uint256[](2);
		ids[0] = a;
		ids[1] = b;
		_assign(GROUP, ids);
		uint256 deadline = block.timestamp + 1 hours;
		_refundGroup(GROUP, ids, deadline);

		assertEq(arena.getLineup(a).owed, ENTRY_CREDIT);
		assertEq(credit.balanceOf(address(creditEntry)), ENTRY_CREDIT);
		_claim(a);
		_claim(b);
		assertEq(arena.getLineup(a).owed, 0);
		assertEq(credit.balanceOf(u1), 100e18);
		assertEq(credit.balanceOf(address(creditEntry)), 0);
		assertEq(arena.pending_credit_recycle(1), 0);
	}

	function test_cancelLineup() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		arena.cancelLineup(_buildCancel(a, u1Pk));
		assertEq(coin.balanceOf(u1), 1000e6); // full refund at cancel
	}

	function test_cancelLineup_revertsAfterGroupWasAssigned() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		_assign(GROUP, _ids4(a, b, c, d));

		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		arena.cancelLineup(_buildCancel(a, u1Pk));
	}

	// ─── freeze ───

	function test_freeze_blocksGroupSettlement() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		vm.prank(owner);
		vm.expectRevert(ArenaMachine.AutomatedAuthorityOnly.selector);
		arena.freezeLineup(a);

		vm.prank(authority);
		arena.freezeLineup(a); // legal: group still ACTIVE

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		ArenaMachine.SettleGroupParams memory p = _buildSettleGroup(GROUP, ids, amounts, outcomes);
		vm.expectRevert(ArenaMachine.LineupNotSettled.selector);
		arena.settleGroup(p);
	}

	function test_freeze_cannotFreezeGroupSettledWinner() public {
		uint256 a = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 b = _place(u2Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 c = _place(u3Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256 d = _place(u4Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		uint256[] memory ids = _ids4(a, b, c, d);
		_assign(GROUP, ids);
		_settleMarkets();
		_settleLineup(a, _picks());
		_settleLineup(b, _picks());
		_settleLineup(c, _picks());
		_settleLineup(d, _picks());

		uint128[] memory amounts = new uint128[](4);
		uint8[] memory outcomes = new uint8[](4);
		amounts[0] = 20e6;
		outcomes[0] = OUTCOME_WIN;
		_settleGroup(GROUP, ids, amounts, outcomes);

		// group already settled -> freezing the winner would strand its owed; must revert
		vm.prank(authority);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.freezeLineup(a);
	}

	// ─── pause ───

	function test_pause_blocksPlacement() public {
		ArenaMachine.PlaceLineupParams memory p = _buildPlace(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		vm.prank(owner);
		arena.pause();
		vm.expectRevert();
		arena.placeLineup(p);
	}

	function _deployArena(address coin_token) internal returns (ArenaMachine) {
		ArenaMachine implementation = new ArenaMachine();
		bytes memory init_data = abi.encodeCall(
			ArenaMachine.initialize,
			(coin_token, address(credit), address(registry), address(vault_factory), authority, owner)
		);
		return ArenaMachine(address(new TransparentUpgradeableProxy(address(implementation), owner, init_data)));
	}

	/// ERC-1967 admin slot: the ProxyAdmin the transparent proxy deployed for itself.
	function _readProxyAdmin(address proxy) internal view returns (address) {
		bytes32 admin_slot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
		return address(uint160(uint256(vm.load(proxy, admin_slot))));
	}

	function test_initialize_revertsOnHighDecimalCoin() public {
		MockCreditToken bad = new MockCreditToken(); // 18 decimals
		ArenaMachine implementation = new ArenaMachine();
		bytes memory init_data = abi.encodeCall(
			ArenaMachine.initialize,
			(address(bad), address(credit), address(registry), address(vault_factory), authority, owner)
		);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		new TransparentUpgradeableProxy(address(implementation), owner, init_data);
	}

	function test_placeLineup_doesNotRevealOrCreateEventMarkets() public {
		ArenaMachine.Pick[] memory picks = _picks();
		assertFalse(registry.getEventMarket(picks[0].event_market_id).is_exists);

		_place(u1Pk, picks, ENTRY_COIN, TOKEN_COIN);

		for (uint256 i = 0; i < picks.length; ++i) {
			assertFalse(registry.getEventMarket(picks[i].event_market_id).is_exists);
		}
	}

	function test_initialize_cannotRunTwice() public {
		vm.expectRevert(Initializable.InvalidInitialization.selector);
		arena.initialize(address(coin), address(credit), address(registry), address(vault_factory), authority, owner);
	}

	function test_upgrade_preservesStateAndSwapsImplementation() public {
		uint256 lineup_id = _place(u1Pk, _picks(), ENTRY_COIN, TOKEN_COIN);
		address new_implementation = address(new ArenaMachine());

		vm.prank(owner);
		ProxyAdmin(arena_proxy_admin)
			.upgradeAndCall(ITransparentUpgradeableProxy(address(arena)), new_implementation, "");

		assertEq(arena.getLineup(lineup_id).owner, vm.addr(u1Pk));
		assertEq(arena.lineupsCount(), 1);
		assertEq(arena.owner(), owner);
	}

	function _refundRevealedMember(uint256 lineup_id) internal {
		ArenaMachine.RefundLineupParams[] memory params = new ArenaMachine.RefundLineupParams[](1);
		params[0] = ArenaMachine.RefundLineupParams(lineup_id, _refundAmount(lineup_id), _picks(), SALT, keccak256(abi.encodePacked(M1, WIN1, M2, WIN2)), REASON_HASH);
		_sendRefundBatch(params);
	}

	function _refundBatch(uint8 token_type) internal returns (ArenaMachine.RefundLineupParams[] memory params) {
		registry.ensureExists(M1);
		registry.ensureExists(M2);
		uint256 first = _place(u1Pk, _picks(), ENTRY_COIN, token_type);
		uint256 second = _place(u2Pk, _picks(), ENTRY_COIN, token_type);
		params = new ArenaMachine.RefundLineupParams[](2);
		params[0] = ArenaMachine.RefundLineupParams(first, _refundAmount(first), _picks(), SALT, keccak256(""), REASON_HASH);
		params[1] = ArenaMachine.RefundLineupParams(second, _refundAmount(second), _picks(), SALT, keccak256(""), REASON_HASH);
	}

	function _signRefundBatch(ArenaMachine.RefundLineupParams[] memory params, uint256 deadline, uint256 chain_id, address target)
		internal view returns (bytes memory)
	{
		bytes32 hash = keccak256(abi.encode(keccak256("arenaBatchRefundLineups"), chain_id, target, params, deadline));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash.toEthSignedMessageHash());
		return abi.encodePacked(r, s, v);
	}

	function _sendRefundBatch(ArenaMachine.RefundLineupParams[] memory params) internal {
		uint256 deadline = block.timestamp + 100;
		arena.batchRefundLineups(params, deadline, _signRefundBatch(params, deadline, block.chainid, address(arena)));
	}

	function _claim(uint256 lineup_id) internal {
		arena.claimRefund(lineup_id);
	}

	function testFuzz_batchRefundLineupsPaysFullEntryAllTokens(uint8 token_type) public {
		token_type = uint8(bound(token_type, 0, 2));
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(token_type);
		uint256 before_balance = token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1);
		uint256 amount = token_type == 0 ? 10e6 : ENTRY_COIN;
		uint256 prize_before = coin.balanceOf(address(prize));
		vm.expectEmit(true, true, false, true, address(arena));
		emit ArenaMachine.LineupRefunded(params[0].lineup_id, u1, amount, REASON_HASH);
		_sendRefundBatch(params);
		assertEq(token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1), before_balance);
		assertEq(coin.balanceOf(address(prize)), prize_before);
		for (uint256 i = 0; i < params.length; ++i) {
			assertEq(arena.getLineup(params[i].lineup_id).status, STATUS_REFUNDED);
			assertEq(arena.getLineup(params[i].lineup_id).owed, amount);
			_claim(params[i].lineup_id);
			assertEq(arena.getLineup(params[i].lineup_id).owed, 0);
		}
		assertEq(token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1), before_balance + amount);
		vm.expectRevert(ArenaMachine.LineupNotActive.selector);
		_sendRefundBatch(params);
	}

	function testFuzz_batchRefundGroupedPaysImmediatelyAndFinalizesWithoutDoublePay(uint8 token_type, bool revealed) public {
		token_type = uint8(bound(token_type, 0, 2));
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(token_type);
		uint256[] memory ids = new uint256[](2);
		ids[0] = params[0].lineup_id;
		ids[1] = params[1].lineup_id;
		_assign(GROUP, ids);
		if (revealed) {
			_settleMarkets();
			_settleLineup(ids[0], _picks());
			params[0].market_results_hash = keccak256(abi.encodePacked(M1, WIN1, M2, WIN2));
			params[1].market_results_hash = params[0].market_results_hash;
		}
		uint256 before_balance = token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1);
		uint256 amount = token_type == 0 ? 10e6 : ENTRY_COIN;
		_sendRefundBatch(params);
		assertEq(token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1), before_balance);
		assertEq(arena.getLineup(ids[0]).owed, amount);
		_claim(ids[0]);
		_claim(ids[1]);
		uint256 refunded_balance = token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1);
		assertEq(refunded_balance, before_balance + amount);
		uint256 deadline = block.timestamp + 100;
		_refundGroup(GROUP, ids, deadline);
		assertEq(token_type == 0 ? coin.balanceOf(u1) : credit.balanceOf(u1), refunded_balance);
		assertEq(arena.getGroup(GROUP).status, 2);
		vm.expectRevert(ArenaMachine.NothingToClaim.selector);
		arena.claimRefund(ids[0]);
	}

	function test_refundBeforeRevealThenSettleRemainingMember() public {
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		uint256[] memory ids = new uint256[](2);
		ids[0] = params[0].lineup_id;
		ids[1] = params[1].lineup_id;
		_assign(GROUP, ids);
		ArenaMachine.RefundLineupParams[] memory one = new ArenaMachine.RefundLineupParams[](1);
		one[0] = params[0];
		vm.recordLogs();
		_sendRefundBatch(one);
		_settleMarkets();
		_settleLineup(ids[1], _picks());
		uint128[] memory amounts = new uint128[](2);
		uint8[] memory outcomes = new uint8[](2);
		amounts[1] = 20e6;
		outcomes[1] = OUTCOME_WIN;
		_settleGroup(GROUP, ids, amounts, outcomes);
		Vm.Log[] memory logs = vm.getRecordedLogs();
		uint256 settled_count;
		for (uint256 i = 0; i < logs.length; ++i) {
			if (logs[i].topics[0] == keccak256("MemberSettled(uint256,address,uint8,uint128)")) {
				assertEq(uint256(logs[i].topics[1]), ids[1]);
				settled_count++;
			}
		}
		assertEq(settled_count, 1);
		_claim(ids[0]);
		arena.claimPrize(ids[1]);
		assertEq(coin.balanceOf(u1), 1000e6);
		assertEq(coin.balanceOf(u2), 1010e6);
		vm.expectRevert(ArenaMachine.GroupNotActive.selector);
		_sendRefundBatch(one);
	}

	function test_batchRefundLineupsMixedLosingAndUnsettled() public {
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		registry.setSettled(M1, WIN1); // Selected outcome is 1: losses are refundable too.
		params[0].market_results_hash = keccak256(abi.encodePacked(M1, WIN1));
		params[1].market_results_hash = params[0].market_results_hash;
		_sendRefundBatch(params);
		assertEq(arena.getLineup(params[1].lineup_id).status, STATUS_REFUNDED);
	}

	function test_batchRefundLineupsIncludesVoidAndEverySettledMarket() public {
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		registry.setSettled(M1, bytes12(0));
		registry.setSettled(M2, WIN2);
		params[0].market_results_hash = keccak256(abi.encodePacked(M1, bytes12(0), M2, WIN2));
		params[1].market_results_hash = params[0].market_results_hash;
		_sendRefundBatch(params);
	}

	function testFuzz_batchRefundLineupsInvalidMemberRollsBack(uint8 failure) public {
		failure = uint8(bound(failure, 0, 8));
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		uint256 before_balance = coin.balanceOf(u1);
		if (failure == 0) {
			params[1].salt = bytes32(uint256(1));
		} else if (failure == 1) {
			params[1].picks[0].outcome_id = WIN1;
		} else if (failure == 2) {
			params[1].market_results_hash = bytes32(0);
		} else if (failure == 3) {
			params[1].lineup_id = params[0].lineup_id;
		} else if (failure == 4) {
			vm.prank(authority);
			arena.freezeLineup(params[1].lineup_id);
		} else if (failure == 5) {
			uint256[] memory ids = new uint256[](1);
			ids[0] = params[1].lineup_id;
			_assign(GROUP, ids);
			uint256 dl = block.timestamp + 100;
			_refundGroup(GROUP, ids, dl);
		} else if (failure == 6) {
			registry.setSettled(M1, WIN1); // stale signed empty results hash
		} else if (failure == 7) {
			params[1].lineup_id = 999;
		} else {
			params[1].picks = new ArenaMachine.Pick[](0);
		}
		uint256 deadline = block.timestamp + 100;
		bytes memory signature = _signRefundBatch(params, deadline, block.chainid, address(arena));
		vm.expectRevert();
		arena.batchRefundLineups(params, deadline, signature);
		assertEq(arena.getLineup(params[0].lineup_id).status, 0);
		assertEq(coin.balanceOf(u1), before_balance);
	}

	function testFuzz_batchRefundLineupsCanonicalRevealRequired(uint8 failure) public {
		failure = uint8(bound(failure, 0, 3));
		ArenaMachine.Pick[] memory picks = _picks();
		if (failure == 0) {
			picks[1].event_market_id = picks[0].event_market_id;
		} else if (failure == 1) {
			(picks[0], picks[1]) = (picks[1], picks[0]);
		}
		registry.ensureExists(M1);
		if (failure != 2) {
			registry.ensureExists(M2);
		}
		ArenaMachine.PlaceLineupParams memory place = _buildPlace(u1Pk, picks, ENTRY_COIN, 0);
		if (failure == 3) {
			place.picks_hash = _picksHash(u2, picks, SALT);
			place.owner_signature = _signPlaceUser(place, arena.wallet_nonce(u1), u1Pk);
			place.automated_authority_signature = _signPlaceAuthority(place);
		}
		arena.placeLineup(place);
		ArenaMachine.RefundLineupParams[] memory params = new ArenaMachine.RefundLineupParams[](1);
		params[0] = ArenaMachine.RefundLineupParams(0, _refundAmount(0), picks, SALT, keccak256(""), REASON_HASH);
		uint256 deadline = block.timestamp + 100;
		bytes memory signature = _signRefundBatch(params, deadline, block.chainid, address(arena));
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.batchRefundLineups(params, deadline, signature);
	}

	function testFuzz_batchRefundLineupsSignatureBindsWholeBatch(uint8 failure) public {
		failure = uint8(bound(failure, 0, 7));
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		uint256 deadline = block.timestamp + 100;
		bytes memory signature = _signRefundBatch(params, deadline, failure == 0 ? block.chainid + 1 : block.chainid, failure == 1 ? address(123) : address(arena));
		if (failure == 2) {
			params[1].salt = bytes32(0);
		} else if (failure == 3) {
			params[1].picks[0].outcome_id = WIN1;
		} else if (failure == 4) {
			params[1].market_results_hash = bytes32(0);
		} else if (failure == 5) {
			params[1].lineup_id = 42;
		} else if (failure == 6) {
			deadline += 1;
		} else if (failure == 7) {
			vm.warp(deadline + 1);
		}
		vm.expectRevert(failure == 7 ? ArenaMachine.SignatureExpired.selector : ArenaMachine.InvalidSignature.selector);
		arena.batchRefundLineups(params, deadline, signature);
	}

	function test_batchRefundLineupsEmptyAndMalformedRegistry() public {
		ArenaMachine.RefundLineupParams[] memory empty = new ArenaMachine.RefundLineupParams[](0);
		vm.expectRevert(ArenaMachine.InvalidInput.selector);
		arena.batchRefundLineups(empty, block.timestamp + 100, "");
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		vm.etch(address(registry), hex"00");
		uint256 deadline = block.timestamp + 100;
		bytes memory signature = _signRefundBatch(params, deadline, block.chainid, address(arena));
		vm.expectRevert();
		arena.batchRefundLineups(params, deadline, signature);
	}

	function test_batchRefundLineupsTypescriptParity() public pure {
		// Same fixed vector and viem-produced personal-sign signature as core-domain test.
		ArenaMachine.Pick[] memory picks = new ArenaMachine.Pick[](2);
		picks[0] = ArenaMachine.Pick(bytes12(uint96(1)), bytes12(uint96(0x64)), bytes8(0));
		picks[1] = ArenaMachine.Pick(bytes12(uint96(2)), bytes12(uint96(0x64)), bytes8(0));
		bytes32 salt = 0x1212121212121212121212121212121212121212121212121212121212121212;
		bytes32 results_hash = keccak256(abi.encodePacked(bytes12(uint96(1)), bytes12(0)));
		assertEq(results_hash, 0x012ca6994aaac2a19371dc816add011ff6915c66948e7eebf8b44ef89b99446f);
		ArenaMachine.RefundLineupParams[] memory params = new ArenaMachine.RefundLineupParams[](2);
		params[0] = ArenaMachine.RefundLineupParams(1, uint128(10e6), picks, salt, results_hash, REASON_HASH);
		params[1] = ArenaMachine.RefundLineupParams(2, uint128(10e6), picks, salt, results_hash, REASON_HASH);
		bytes32 hash = keccak256(abi.encode(keccak256("arenaBatchRefundLineups"), uint256(8453), address(0x123), params, uint256(1767225600)));
		assertEq(hash, 0x216717faba391602e51beb42df6dadc5ca0dcc9506846b75e5a1ad5874825d10);
		assertEq(keccak256(abi.encode(PICKS_COMMITMENT_TYPEHASH, uint256(8453), address(0x123), address(0xdead), picks, salt)), 0x0119d847d208ea19acfda13a7d33be58109120a8ee81ce4f2e53df646701cc02);
		bytes memory signature = hex"d98b5ad8f1259368fa0c9d53276b87188f29bf77d7788a423cc6701151ee8f2332f5580bd102d10f9aa364023c4e2b7384a81778329a39280950612dc2061f1a1b";
		assertEq(ECDSA.recover(hash.toEthSignedMessageHash(), signature), 0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A);
	}

	function test_batchRefundLineupsVaultFailureRollsBackAllMembers() public {
		ArenaMachine.RefundLineupParams[] memory params = _refundBatch(0);
		uint256 before_balance = coin.balanceOf(u1);
		_sendRefundBatch(params);
		assertEq(arena.getLineup(params[0].lineup_id).status, STATUS_REFUNDED);
		assertEq(arena.getLineup(params[0].lineup_id).owed, 10e6);
		vm.mockCallRevert(address(entry), abi.encodeWithSignature("payout(address,address,uint256)", u2, address(coin), uint256(10e6)), "vault-failed");
		uint256[] memory ids = new uint256[](2);
		ids[0] = params[0].lineup_id;
		ids[1] = params[1].lineup_id;
		vm.expectRevert();
		arena.batchClaimRefund(ids);
		assertEq(arena.getLineup(params[0].lineup_id).owed, 10e6);
		assertEq(arena.getLineup(params[1].lineup_id).owed, 10e6);
		assertEq(coin.balanceOf(u1), before_balance);
	}
}
