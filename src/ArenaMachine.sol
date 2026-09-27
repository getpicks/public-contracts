// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IEventMarketRegistry} from "./IEventMarketRegistry.sol";
import {IVaultFactory} from "./IVaultFactory.sol";
import {IEntryVault} from "./IEntryVault.sol";
import {IPrizeTreasury} from "./IPrizeTreasury.sol";

interface IArenaCreditTokenPolicy {
    // forge-lint: disable-next-line(mixed-case-function)
    function whitelisted_addresses(address account) external view returns (bool);
}

interface IArenaVaultPolicy {
    // forge-lint: disable-next-line(mixed-case-function)
    function token_policy(address token)
        external
        view
        returns (bool supported, uint256 min_balance, uint256 max_drain_per_tx);

    // forge-lint: disable-next-line(mixed-case-function)
    function whitelisted_contracts(address contract_address) external view returns (bool);
}

/// @title ArenaMachine — Picks Arena V3 group-based P2P contest engine
///
/// @notice GAMEPLAY RULES LIVE OFF-CHAIN. The contract is a verifier + fund router
///         across two settlement layers:
///
///         Layer 1 — settleLineup(): reveals and verifies each lineup's committed picks,
///           requires every referenced EventMarketRegistry market to be settled, then
///           marks the lineup settled. No scoring.
///
///         Layer 2 — settleGroup(): the server computes prizes off-chain and submits
///           per-member (amount, outcome), bounds each amount, records `owed`
///           and sets status. Winners pull via claimPrize() from the PrizeTreasury.
///           Refunds are marked separately (owed from EntryVault) and pulled via
///           claimRefund(). The two vaults never commingle (spec §7).
///
///         Groups are matched off-chain; the group id is derived off-chain (from the
///         matchmaker's variables) and passed in — the contract only requires it is
///         unique and binds the frozen member set via members_hash.
///
/// @dev On-chain guards (rules trusted; inputs + funds are not): refund amount must
///      equal the full entry, win <= max_multiplier * entry (locked at placement),
///      PrizeTreasury floor, settled-market verification, pull-based auditable `owed`.
///      Holds no funds itself.
contract ArenaMachine is Initializable, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 internal constant PICKS_COMMITMENT_TYPEHASH = keccak256("picksCommitment");
    bytes32 internal constant PLACE_LINEUP_USER_TYPEHASH = keccak256("arenaPlaceLineupUser");
    bytes32 internal constant PLACE_LINEUP_AUTHORITY_TYPEHASH = keccak256("arenaPlaceLineupAuthority");
    bytes32 internal constant ASSIGN_GROUP_TYPEHASH = keccak256("arenaAssignGroup");
    bytes32 internal constant SETTLE_LINEUP_TYPEHASH = keccak256("arenaSettleLineup");
    bytes32 internal constant BATCH_SETTLE_LINEUP_TYPEHASH = keccak256("arenaBatchSettleLineup");
    bytes32 internal constant SETTLE_GROUP_TYPEHASH = keccak256("arenaSettleGroup");
    bytes32 internal constant CANCEL_LINEUP_TYPEHASH = keccak256("arenaCancelLineup");
    bytes32 internal constant BATCH_REFUND_LINEUPS_TYPEHASH = keccak256("arenaBatchRefundLineups");
    bytes32 internal constant REFUND_GROUP_TYPEHASH = keccak256("arenaRefundGroup");

    // ─── Lineup status ───
    uint8 internal constant STATUS_ACTIVE = 0; // placed, not yet layer-1 settled
    uint8 internal constant STATUS_FROZEN = 1; // admin hold — blocks group settlement
    uint8 internal constant STATUS_SETTLED = 2; // layer-1 reveal verified; after settleGroup, win owed>0 / loss owed==0
    uint8 internal constant STATUS_REFUNDED = 3; // full refund owed from EntryVault
    uint8 internal constant STATUS_CANCELED = 4; // user cancel (refunded at cancel time)

    // ─── Group status ───
    uint8 internal constant GROUP_STATUS_ACTIVE = 0;
    uint8 internal constant GROUP_STATUS_SETTLED = 1;
    uint8 internal constant GROUP_STATUS_REFUNDED = 2;

    // ─── Per-member settlement outcome (server-supplied, layer 2) ───
    uint8 internal constant OUTCOME_LOST = 0;
    uint8 internal constant OUTCOME_WIN = 1; // paid from PrizeTreasury (coin or credit, by token type)

    uint8 internal constant INTERNAL_DECIMALS = 18;
    uint8 internal constant TOKEN_TYPE_COIN = 0;
    uint8 internal constant TOKEN_TYPE_CREDIT_TO_COIN = 1;
    uint8 internal constant TOKEN_TYPE_CREDIT_TO_CREDIT = 2;

    uint16 internal constant DEFAULT_MIN_PICKS_COUNT = 2;
    uint16 internal constant DEFAULT_MAX_PICKS_COUNT = 6;
    // Minimum group size and pick-count buckets are product rules enforced off-chain.
    uint16 internal constant MAX_GROUP_SIZE_LIMIT = 96; // absolute ceiling so a group is always settleable/refundable in one tx

    struct Pick {
        bytes12 event_market_id;
        bytes12 outcome_id;
        bytes8 _reserved;
    }

    struct Lineup {
        address owner;
        uint8 status;
        uint8 token_type;
        uint16 vault_pair_id;
        uint128 size; // internal (18) decimals
        uint32 max_multiplier; // hundredths; payout bound = entry * max_multiplier / 100. Locked at placement.
        uint128 owed; // pull-based prize or refund (destination token's own decimals)
        bytes32 group_id; // bytes32(0) = unassigned; off-chain-derived id once grouped
        bytes32 picks_hash;
    }

    struct Group {
        uint8 status;
        uint16 member_count;
        uint48 created_at;
        bytes32 members_hash; // keccak256(abi.encode(sorted member lineup ids))
    }

    struct CoinConfig {
        address token_address;
        uint8 decimals;
    }

    struct PlaceLineupParams {
        bytes32 picks_hash;
        uint128 size;
        uint8 token_type;
        uint16 vault_pair_id;
        uint32 max_multiplier; // hundredths; authority-approved payout bound
        address owner_address;
        uint256 deadline;
        bytes owner_signature;
        bytes automated_authority_signature;
    }

    struct SettleLineupParams {
        uint256 lineup_id;
        Pick[] picks;
        bytes32 salt;
        uint256 deadline;
        bytes automated_authority_signature;
    }

    struct SettleGroupParams {
        bytes32 group_id;
        uint256[] member_lineup_ids; // sorted ascending, == the frozen member set
        uint128[] amounts; // prize-token decimals; loss must be 0
        uint8[] outcomes; // per member OUTCOME_*
        uint256 deadline;
        bytes automated_authority_signature;
    }

    struct RefundLineupParams {
        uint256 lineup_id;
        uint128 amount;
        Pick[] picks;
        bytes32 salt;
        bytes32 market_results_hash;
        bytes32 reason_hash;
    }

    struct CancelLineupParams {
        uint256 lineup_id;
        address owner_address;
        uint256 deadline;
        bytes owner_signature;
        bytes automated_authority_signature;
    }

    CoinConfig public coin_config;
    // 10 ** (INTERNAL_DECIMALS - coin decimals); precomputed at init to avoid a per-call EXP.
    uint256 public coin_scale;
    address public owner;
    address public credit_token_address;
    // Where consumed entry credit is recycled (the credit vault). The vault is token-agnostic;
    // the machine owns this policy and passes it to EntryVault.payout on recycle.
    address public credit_recycle_address;
    address public automated_authority_address;
    address public event_market_registry_address;
    address public vault_factory_address;

    // Authority-approved payout ceiling (hundredths). A cap of 0 allows no placements.
    uint64 public max_multiplier_cap;

    // Group-size safety ceiling and admission pick-count policy. Placement remains private;
    // the authority checks pick counts before signing. New limits never restrict existing reveals.
    uint16 public max_group_size;
    uint16 public min_picks_count;
    uint16 public max_picks_count;

    Lineup[] public lineups;
    mapping(bytes32 => Group) internal groups;
    uint256 public groups_count;
    mapping(address => uint256) public wallet_nonce;

    // Consumed entry credit (from won + lost credit-funded lineups) accrues here per vault pair
    // and is recycled back to the credit vault in a periodic batch. Keeps settleGroup free of
    // external calls, so it can never be reentered.
    mapping(uint16 => uint256) public pending_credit_recycle;

    // Current placement vault pair per token type. Historical lineups retain their own pair id.
    mapping(uint8 => uint16) public vault_pair_id_by_token_type;
    mapping(uint8 => bool) public vault_pair_configured_by_token_type;

    event LineupPlaced(
        uint256 indexed lineup_id,
        address indexed owner,
        uint16 vault_pair_id,
        uint128 size,
        uint8 token_type,
        uint256 wallet_nonce
    );
    event GroupAssigned(bytes32 indexed group_id, uint256[] member_lineup_ids);
    event LineupRevealed(uint256 indexed lineup_id, Pick[] picks, bytes32 salt);
    event GroupSettled(bytes32 indexed group_id);
    event MemberSettled(uint256 indexed lineup_id, address indexed owner, uint8 outcome, uint128 owed);
    event PrizeClaimed(uint256 indexed lineup_id, address indexed owner, uint128 amount);
    event RefundClaimed(uint256 indexed lineup_id, address indexed owner, uint128 amount);
    event ConsumedCreditRecycled(uint16 indexed vault_pair_id, uint256 amount);
    event CreditRecycleAddressUpdated(address indexed credit_recycle_address);
    event TokenTypeVaultPairUpdated(uint8 indexed token_type, uint16 indexed vault_pair_id);
    event LineupCanceled(uint256 indexed lineup_id, address indexed owner, uint256 amount);
    event LineupFrozen(uint256 indexed lineup_id);
    event LineupUnfrozen(uint256 indexed lineup_id);
    event AutomatedAuthorityUpdated(address indexed automated_authority);
    event VaultFactoryUpdated(address indexed vault_factory);
    event MaxGroupSizeUpdated(uint16 max_group_size);
    event PickCountLimitsUpdated(uint16 min_picks_count, uint16 max_picks_count);
    event GroupRefunded(bytes32 indexed group_id, bytes32 reason_hash);
    event LineupRefunded(uint256 indexed lineup_id, address indexed owner, uint256 amount, bytes32 reason_hash);
    event MaxMultiplierCapUpdated(uint64 max_multiplier_cap);
    event OwnershipTransferred(address indexed previous_owner, address indexed new_owner);

    error InvalidInput();
    error InvalidSignature();
    error SignatureExpired();
    error VaultPairInactive();
    error LineupDoesNotExist();
    error LineupNotActive();
    error LineupNotSettled();
    error LineupNotFrozen();
    error GroupDoesNotExist();
    error GroupAlreadyExists();
    error GroupNotActive();
    error GroupTooLarge();
    error MembersMismatch();
    error EventMarketsNotSettled();
    error PayoutTooHigh();
    error MultiplierExceedsCap();
    error NothingToClaim();
    error AutomatedAuthorityOnly();
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    modifier onlyOwner() {
        if (owner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    modifier onlyAutomatedAuthority() {
        if (msg.sender != automated_authority_address) revert AutomatedAuthorityOnly();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _coin_token,
        address _credit_token,
        address _event_market_registry,
        address _vault_factory,
        address _automated_authority,
        address _owner
    ) external initializer {
        if (_coin_token == address(0) || _credit_token == address(0)) revert InvalidInput();
        if (_event_market_registry == address(0) || _vault_factory == address(0)) revert InvalidInput();
        if (_automated_authority == address(0) || _owner == address(0)) revert InvalidInput();

        // The coin must have strictly fewer decimals than the internal 18-decimal accounting
        // unit, so _toCoinDecimals always scales DOWN (>= 18 would underflow / be a no-op).
        uint8 coin_decimals = IERC20Metadata(_coin_token).decimals();
        if (coin_decimals >= INTERNAL_DECIMALS) revert InvalidInput();
        coin_config = CoinConfig({token_address: _coin_token, decimals: coin_decimals});
        coin_scale = 10 ** (INTERNAL_DECIMALS - coin_decimals);
        // Credit amounts use internal units directly on every entry, prize and refund path.
        if (IERC20Metadata(_credit_token).decimals() != INTERNAL_DECIMALS) revert InvalidInput();
        credit_token_address = _credit_token;
        event_market_registry_address = _event_market_registry;
        vault_factory_address = _vault_factory;
        automated_authority_address = _automated_authority;
        min_picks_count = DEFAULT_MIN_PICKS_COUNT;
        max_picks_count = DEFAULT_MAX_PICKS_COUNT;
        _transferOwnership(_owner);
    }

    function transferOwnership(address new_owner) external onlyOwner {
        if (new_owner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(new_owner);
    }

    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address new_owner) internal {
        address old_owner = owner;
        owner = new_owner;
        emit OwnershipTransferred(old_owner, new_owner);
    }

    // ─── Placement ───

    function placeLineup(PlaceLineupParams calldata params) external whenNotPaused {
        _placeLineup(params);
    }

    /// @notice Places several lineups in one tx (each individually owner+authority signed).
    function batchPlaceLineup(PlaceLineupParams[] calldata params) external whenNotPaused {
        for (uint256 i = 0; i < params.length; ++i) {
            _placeLineup(params[i]);
        }
    }

    function _placeLineup(PlaceLineupParams calldata params) internal {
        if (block.timestamp > params.deadline) revert SignatureExpired();
        if (params.size == 0 || params.picks_hash == bytes32(0)) revert InvalidInput();
        if (!_isSupportedTokenType(params.token_type)) revert InvalidInput();
        if (!vault_pair_configured_by_token_type[params.token_type]) revert InvalidInput();
        if (vault_pair_id_by_token_type[params.token_type] != params.vault_pair_id) revert InvalidInput();
        if (params.max_multiplier == 0 || params.max_multiplier > max_multiplier_cap) revert MultiplierExceedsCap();

        uint256 nonce = wallet_nonce[params.owner_address];
        _verifyPlaceSignatures(params, nonce);
        wallet_nonce[params.owner_address] = nonce + 1; // bump BEFORE the external pull (CEI): a hooked token can't reenter and double-place
        _pullEntry(params);

        lineups.push(
            Lineup({
                owner: params.owner_address,
                status: STATUS_ACTIVE,
                token_type: params.token_type,
                vault_pair_id: params.vault_pair_id,
                size: params.size,
                max_multiplier: params.max_multiplier,
                owed: 0,
                group_id: bytes32(0),
                picks_hash: params.picks_hash
            })
        );

        // wallet_nonce is emitted so the off-chain worker can recompute the queued lineup's deterministic
        // id (hash(chain, this, owner, nonce)) and correlate this on-chain lineup back to it.
        emit LineupPlaced(
            lineups.length - 1, params.owner_address, params.vault_pair_id, params.size, params.token_type, nonce
        );
    }

    function _verifyPlaceSignatures(PlaceLineupParams calldata params, uint256 nonce) internal view {
        {
            bytes32 user_hash = keccak256(
                abi.encode(
                    PLACE_LINEUP_USER_TYPEHASH,
                    block.chainid,
                    address(this),
                    params.picks_hash,
                    params.size,
                    params.token_type,
                    params.owner_address,
                    nonce,
                    params.deadline
                )
            );
            if (user_hash.toEthSignedMessageHash().recover(params.owner_signature) != params.owner_address) {
                revert InvalidSignature();
            }
        }
        {
            bytes32 authority_hash = keccak256(
                abi.encode(
                    PLACE_LINEUP_AUTHORITY_TYPEHASH,
                    block.chainid,
                    address(this),
                    params.picks_hash,
                    params.size,
                    params.token_type,
                    params.vault_pair_id,
                    params.max_multiplier,
                    params.owner_address,
                    nonce,
                    params.deadline
                )
            );
            if (
                authority_hash.toEthSignedMessageHash().recover(params.automated_authority_signature)
                    != automated_authority_address
            ) revert InvalidSignature();
        }
    }

    function _pullEntry(PlaceLineupParams calldata params) internal {
        (address entry_vault,, bool is_active) = IVaultFactory(vault_factory_address).getVaultPair(params.vault_pair_id);
        if (!is_active) revert VaultPairInactive();

        address entry_token = _isCreditEntry(params.token_type) ? credit_token_address : coin_config.token_address;
        uint256 entry_amount =
            _isCreditEntry(params.token_type) ? uint256(params.size) : _toCoinDecimals(uint256(params.size));
        IEntryVault(entry_vault).depositFor(params.owner_address, entry_token, entry_amount);
    }

    // ─── Grouping ───

    /// @notice Commits a filled group. `group_id` is derived off-chain by the matchmaker
    ///         and passed in; the contract only requires it is non-zero and unused, links
    ///         each member, and freezes the member set via members_hash. Authority-signed.
    function assignGroup(
        bytes32 group_id,
        uint256[] calldata member_lineup_ids,
        uint256 signature_deadline,
        bytes calldata automated_authority_signature
    ) external whenNotPaused {
        if (block.timestamp > signature_deadline) revert SignatureExpired();
        if (group_id == bytes32(0)) revert InvalidInput();
        if (groups[group_id].member_count != 0) revert GroupAlreadyExists();

        uint256 count = member_lineup_ids.length;
        if (count == 0) revert InvalidInput();

        bytes32 message_hash = keccak256(
            abi.encode(
                ASSIGN_GROUP_TYPEHASH, block.chainid, address(this), group_id, member_lineup_ids, signature_deadline
            )
        );
        if (message_hash.toEthSignedMessageHash().recover(automated_authority_signature) != automated_authority_address)
        {
            revert InvalidSignature();
        }

        if (count > max_group_size) revert GroupTooLarge();

        for (uint256 i = 0; i < count; ++i) {
            uint256 id = member_lineup_ids[i];
            Lineup storage lineup = lineups[_requireLineup(id)];
            if (lineup.status != STATUS_ACTIVE) revert LineupNotActive();
            if (lineup.group_id != bytes32(0)) revert LineupNotActive();
            if (i > 0 && id <= member_lineup_ids[i - 1]) revert MembersMismatch(); // strictly ascending → canonical set
            lineup.group_id = group_id;
        }

        groups[group_id] = Group({
            status: GROUP_STATUS_ACTIVE,
            member_count: uint16(count),
            created_at: uint48(block.timestamp),
            members_hash: keccak256(abi.encode(member_lineup_ids))
        });
        groups_count += 1;
        emit GroupAssigned(group_id, member_lineup_ids);
    }

    // ─── Layer 1: reveal and registry verification ───

    /// @notice Reveals a lineup's picks. Reverts unless the commitment matches and every
    ///         referenced market is settled on the registry. No scoring and no `owed`.
    function settleLineup(SettleLineupParams calldata params) external whenNotPaused {
        if (block.timestamp > params.deadline) revert SignatureExpired();

        bytes32 message_hash = keccak256(
            abi.encode(
                SETTLE_LINEUP_TYPEHASH,
                block.chainid,
                address(this),
                params.lineup_id,
                params.picks,
                params.salt,
                params.deadline
            )
        );
        if (
            message_hash.toEthSignedMessageHash().recover(params.automated_authority_signature)
                != automated_authority_address
        ) revert InvalidSignature();

        _settleLineup(params.lineup_id, params.picks, params.salt);
    }

    /// @notice Anchors several members' outcomes in one tx, under a single authority signature.
    function batchSettleLineup(
        uint256[] calldata lineup_ids,
        Pick[][] calldata picks_array,
        bytes32[] calldata salts,
        uint256 deadline,
        bytes calldata automated_authority_signature
    ) external whenNotPaused {
        if (block.timestamp > deadline) revert SignatureExpired();
        uint256 n = lineup_ids.length;
        if (n == 0 || n != picks_array.length || n != salts.length) revert InvalidInput();

        bytes32 message_hash = keccak256(
            abi.encode(
                BATCH_SETTLE_LINEUP_TYPEHASH, block.chainid, address(this), lineup_ids, picks_array, salts, deadline
            )
        );
        if (message_hash.toEthSignedMessageHash().recover(automated_authority_signature) != automated_authority_address)
        {
            revert InvalidSignature();
        }

        for (uint256 i = 0; i < n; ++i) {
            _settleLineup(lineup_ids[i], picks_array[i], salts[i]);
        }
    }

    function _settleLineup(uint256 lineup_id, Pick[] calldata picks, bytes32 salt) internal {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        if (lineup.status != STATUS_ACTIVE) revert LineupNotActive();
        if (lineup.group_id == bytes32(0)) revert LineupNotActive(); // must be grouped first
        if (_computePicksHash(lineup.owner, picks, salt) != lineup.picks_hash) revert InvalidInput();

        _verifySettledMarkets(picks);
        lineup.status = STATUS_SETTLED;
        emit LineupRevealed(lineup_id, picks, salt);
    }

    /// @dev Requires canonical market order and a final registry result for every pick.
    function _verifySettledMarkets(Pick[] calldata picks) internal view {
        IEventMarketRegistry registry = IEventMarketRegistry(event_market_registry_address);
        bytes12 prev = bytes12(0);
        uint256 n = picks.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes12 market_id = picks[i].event_market_id;
            if (i > 0 && market_id <= prev) revert InvalidInput();
            if (!registry.getEventMarket(market_id).is_settled) revert EventMarketsNotSettled();
            prev = market_id;
        }
    }

    // ─── Layer 2: group settlement (apply off-chain-computed payouts) ───

    function settleGroup(SettleGroupParams calldata params) external whenNotPaused {
        if (block.timestamp > params.deadline) revert SignatureExpired();

        Group storage group = groups[params.group_id];
        if (group.member_count == 0 || group.status != GROUP_STATUS_ACTIVE) revert GroupNotActive();

        uint256 count = params.member_lineup_ids.length;
        if (count != group.member_count || count != params.amounts.length || count != params.outcomes.length) {
            revert MembersMismatch();
        }
        if (keccak256(abi.encode(params.member_lineup_ids)) != group.members_hash) revert MembersMismatch();

        _verifySettleGroupSig(params);

        _applyGroupOutcomes(params);

        group.status = GROUP_STATUS_SETTLED;
        emit GroupSettled(params.group_id);
    }

    function _verifySettleGroupSig(SettleGroupParams calldata params) internal view {
        bytes32 message_hash = keccak256(
            abi.encode(
                SETTLE_GROUP_TYPEHASH,
                block.chainid,
                address(this),
                params.group_id,
                params.member_lineup_ids,
                params.amounts,
                params.outcomes,
                params.deadline
            )
        );
        if (
            message_hash.toEthSignedMessageHash().recover(params.automated_authority_signature)
                != automated_authority_address
        ) revert InvalidSignature();
    }

    /// @dev Applies each authority-signed member outcome after every lineup has completed
    ///      reveal and registry verification in layer 1.
    function _applyGroupOutcomes(SettleGroupParams calldata params) internal {
        uint256 count = params.member_lineup_ids.length;
        for (uint256 i = 0; i < count; ++i) {
            uint256 id = params.member_lineup_ids[i];
            Lineup storage lineup = lineups[_requireLineup(id)];
            if (lineup.group_id != params.group_id) revert MembersMismatch();
            if (params.outcomes[i] > OUTCOME_WIN) {
                revert InvalidInput();
            }
            if (lineup.status == STATUS_REFUNDED) {
                // Full roster remains signed; refunded members receive no settlement event or payout.
                if (params.outcomes[i] != OUTCOME_LOST || params.amounts[i] != 0) {
                    revert InvalidInput();
                }
                continue;
            }
            if (lineup.status != STATUS_SETTLED) revert LineupNotSettled();
            _applyMemberOutcome(lineup, id, params.outcomes[i], params.amounts[i]);
        }
    }

    function _applyMemberOutcome(Lineup storage lineup, uint256 lineup_id, uint8 outcome, uint128 amount) internal {
        bool is_credit_entry = _isCreditEntry(lineup.token_type);

        if (outcome == OUTCOME_WIN) {
            uint256 prize_entry =
                _isCreditPrize(lineup.token_type) ? uint256(lineup.size) : _toCoinDecimals(uint256(lineup.size));
            uint256 max_payout = (prize_entry * uint256(lineup.max_multiplier)) / 100;
            if (uint256(amount) > max_payout) revert PayoutTooHigh();
            lineup.owed = amount;
            lineup.status = STATUS_SETTLED;
            if (is_credit_entry) pending_credit_recycle[lineup.vault_pair_id] += lineup.size;
        } else if (outcome == OUTCOME_LOST) {
            if (amount != 0) {
                revert InvalidInput();
            }
            lineup.status = STATUS_SETTLED; // owed stays 0
            if (is_credit_entry) pending_credit_recycle[lineup.vault_pair_id] += lineup.size;
        } else {
            revert InvalidInput();
        }

        emit MemberSettled(lineup_id, lineup.owner, outcome, lineup.owed);
    }

    // ─── Claim (pull-based prize / refund) ───

    function _takeOwed(Lineup storage lineup) internal returns (uint128 amount) {
        amount = lineup.owed;
        if (amount == 0) revert NothingToClaim();
        lineup.owed = 0;
    }

    function claimPrize(uint256 lineup_id) public whenNotPaused {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        if (lineup.status != STATUS_SETTLED) revert NothingToClaim();
        uint128 amount = _takeOwed(lineup);
        (, address prize_treasury,) = IVaultFactory(vault_factory_address).getVaultPair(lineup.vault_pair_id);
        address token = _isCreditPrize(lineup.token_type) ? credit_token_address : coin_config.token_address;
        IPrizeTreasury(prize_treasury).payout(lineup.owner, token, amount);
        emit PrizeClaimed(lineup_id, lineup.owner, amount);
    }

    function claimRefund(uint256 lineup_id) public whenNotPaused {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        if (lineup.status != STATUS_REFUNDED) revert NothingToClaim();
        uint128 amount = _takeOwed(lineup);
        (address entry_vault,,) = IVaultFactory(vault_factory_address).getVaultPair(lineup.vault_pair_id);
        address token = _isCreditEntry(lineup.token_type) ? credit_token_address : coin_config.token_address;
        IEntryVault(entry_vault).payout(lineup.owner, token, amount);
        emit RefundClaimed(lineup_id, lineup.owner, amount);
    }

    function batchClaimPrize(uint256[] calldata lineup_ids) external {
        for (uint256 i = 0; i < lineup_ids.length; ++i) {
            claimPrize(lineup_ids[i]);
        }
    }

    function batchClaimRefund(uint256[] calldata lineup_ids) external {
        for (uint256 i = 0; i < lineup_ids.length; ++i) {
            claimRefund(lineup_ids[i]);
        }
    }

    // ─── Cancel (full refund of an ungrouped lineup; window enforced off-chain by the authority sig) ───

    function cancelLineup(CancelLineupParams calldata params) external whenNotPaused {
        if (block.timestamp > params.deadline) revert SignatureExpired();
        Lineup storage lineup = lineups[_requireLineup(params.lineup_id)];
        if (lineup.status != STATUS_ACTIVE) revert LineupNotActive();
        if (lineup.group_id != bytes32(0)) revert LineupNotActive();
        if (lineup.owner != params.owner_address) revert InvalidInput();

        bytes32 message_hash = keccak256(
            abi.encode(
                CANCEL_LINEUP_TYPEHASH,
                block.chainid,
                address(this),
                params.lineup_id,
                params.owner_address,
                params.deadline
            )
        );
        if (message_hash.toEthSignedMessageHash().recover(params.owner_signature) != params.owner_address) {
            revert InvalidSignature();
        }
        if (
            message_hash.toEthSignedMessageHash().recover(params.automated_authority_signature)
                != automated_authority_address
        ) revert InvalidSignature();

        (address entry_vault,,) = IVaultFactory(vault_factory_address).getVaultPair(lineup.vault_pair_id);
        lineup.status = STATUS_CANCELED;

        address token = _isCreditEntry(lineup.token_type) ? credit_token_address : coin_config.token_address;
        uint256 amount =
            _isCreditEntry(lineup.token_type) ? uint256(lineup.size) : _toCoinDecimals(uint256(lineup.size));
        IEntryVault(entry_vault).payout(lineup.owner, token, amount);
        emit LineupCanceled(params.lineup_id, lineup.owner, amount);
    }

    // ─── Emergency / server refunds ───

    function _fullRefundAmount(Lineup storage lineup) internal view returns (uint128) {
        return uint128(
            _isCreditEntry(lineup.token_type) ? uint256(lineup.size) : _toCoinDecimals(uint256(lineup.size))
        );
    }

    function _markRefund(uint256 lineup_id, uint128 amount, bytes32 reason_hash) internal {
        if (reason_hash == bytes32(0)) revert InvalidInput();
        Lineup storage lineup = lineups[lineup_id];
        // 0 returns no funds (refund_policy 1). Otherwise amount must be the full entry.
        if (amount != 0 && amount != _fullRefundAmount(lineup)) revert InvalidInput();
        lineup.owed = amount;
        emit LineupRefunded(lineup_id, lineup.owner, amount, reason_hash);
    }

    /// @notice Marks one or more lineups refunded with owner-bound reveal proofs, including members of active groups.
    /// @dev Members claim owed refunds later. Accepts already-revealed members of an active group.
    /// @dev Hash is keccak256 of packed (bytes12 market id, bytes12 winning outcome) pairs
    ///      in pick order, omitting unsettled markets. No settled markets => keccak256("").
    function batchRefundLineups(
        RefundLineupParams[] calldata params,
        uint256 deadline,
        bytes calldata automated_authority_signature
    ) external whenNotPaused {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (params.length == 0) revert InvalidInput();
        bytes32 message_hash = keccak256(
            abi.encode(BATCH_REFUND_LINEUPS_TYPEHASH, block.chainid, address(this), params, deadline)
        );
        if (message_hash.toEthSignedMessageHash().recover(automated_authority_signature) != automated_authority_address) {
            revert InvalidSignature();
        }
        // Validate and mark EVERY member before recording owed (batch-wide CEI).
        // Payout is a later claim so a large batch cannot run out of gas transferring.
        for (uint256 i = 0; i < params.length; ++i) {
            RefundLineupParams calldata param = params[i];
            Lineup storage lineup = lineups[_requireLineup(param.lineup_id)];
            _requireRefundable(lineup);
            if (_computePicksHash(lineup.owner, param.picks, param.salt) != lineup.picks_hash) revert InvalidInput();
            if (_settledMarketResultsHash(param.picks) != param.market_results_hash) revert InvalidInput();
            lineup.status = STATUS_REFUNDED; // also rejects duplicate members
        }
        for (uint256 i = 0; i < params.length; ++i) {
            _markRefund(params[i].lineup_id, params[i].amount, params[i].reason_hash);
        }
    }

    function _requireRefundable(Lineup storage lineup) internal view {
        if (lineup.group_id == bytes32(0)) {
            if (lineup.status != STATUS_ACTIVE) {
                revert LineupNotActive();
            }
        } else {
            if (groups[lineup.group_id].status != GROUP_STATUS_ACTIVE) {
                revert GroupNotActive();
            }
            if (lineup.status != STATUS_ACTIVE && lineup.status != STATUS_SETTLED) {
                revert LineupNotActive();
            }
        }
    }

    function _settledMarketResultsHash(Pick[] calldata picks) internal view returns (bytes32) {
        bytes memory results;
        IEventMarketRegistry registry = IEventMarketRegistry(event_market_registry_address);
        for (uint256 i = 0; i < picks.length; ++i) {
            bytes12 market_id = picks[i].event_market_id;
            if (i > 0 && market_id <= picks[i - 1].event_market_id) revert InvalidInput();
            IEventMarketRegistry.EventMarket memory market = registry.getEventMarket(market_id);
            if (!market.is_exists) revert InvalidInput();
            if (market.is_settled) {
                results = bytes.concat(results, market_id, market.winning_outcome_id);
            }
        }
        return keccak256(results);
    }

    /// @notice Authority-signed full refund for every member of a locked group when
    ///         settlement cannot safely continue. The owner has no gameplay authority.
    function refundGroup(
        bytes32 group_id,
        uint256[] calldata member_lineup_ids,
        uint128[] calldata amounts,
        bytes32 reason_hash,
        uint256 deadline,
        bytes calldata automated_authority_signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        bytes32 message_hash = keccak256(
            abi.encode(
                REFUND_GROUP_TYPEHASH,
                block.chainid,
                address(this),
                group_id,
                member_lineup_ids,
                amounts,
                reason_hash,
                deadline
            )
        );
        if (message_hash.toEthSignedMessageHash().recover(automated_authority_signature) != automated_authority_address)
        {
            revert InvalidSignature();
        }
        _refundGroup(group_id, member_lineup_ids, amounts, reason_hash);
    }

    function _refundGroup(
        bytes32 group_id,
        uint256[] calldata member_lineup_ids,
        uint128[] calldata amounts,
        bytes32 reason_hash
    ) internal {
        if (reason_hash == bytes32(0)) revert InvalidInput();
        Group storage group = groups[group_id];
        if (group.member_count == 0 || group.status != GROUP_STATUS_ACTIVE) revert GroupNotActive();

        uint256 count = member_lineup_ids.length;
        if (count != group.member_count || count != amounts.length) revert MembersMismatch();
        if (keccak256(abi.encode(member_lineup_ids)) != group.members_hash) revert MembersMismatch();

        bool[] memory pay_members = new bool[](count);
        for (uint256 i = 0; i < count; ++i) {
            Lineup storage lineup = lineups[_requireLineup(member_lineup_ids[i])];
            if (lineup.group_id != group_id) revert MembersMismatch();
            if (i > 0 && member_lineup_ids[i] <= member_lineup_ids[i - 1]) {
                revert MembersMismatch();
            }
            if (lineup.status == STATUS_REFUNDED) {
                if (amounts[i] != 0) {
                    revert InvalidInput();
                }
                continue;
            }
            _requireRefundable(lineup);
            lineup.status = STATUS_REFUNDED;
            pay_members[i] = true;
        }
        // Mark the complete batch and group. Members claim owed refunds separately.
        group.status = GROUP_STATUS_REFUNDED;
        for (uint256 i = 0; i < count; ++i) {
            if (pay_members[i]) {
                _markRefund(member_lineup_ids[i], amounts[i], reason_hash);
            }
        }
        emit GroupRefunded(group_id, reason_hash);
    }

    /// @notice Recycles consumed credit (won + lost credit-funded lineups) accrued for a vault
    ///         pair back to the credit vault, so it can be re-distributed instead of re-minted.
    ///         Called periodically (e.g. daily) by the owner or authority. settleGroup only accrues,
    ///         so the amount is fully on-chain and can't be over/under-recycled.
    function recycleConsumedCredit(uint16 vault_pair_id) external onlyAutomatedAuthority {
        if (credit_recycle_address == address(0)) revert InvalidInput();
        uint256 amount = pending_credit_recycle[vault_pair_id];
        if (amount == 0) return;
        pending_credit_recycle[vault_pair_id] = 0; // effect before interaction (CEI)
        (address entry_vault,,) = IVaultFactory(vault_factory_address).getVaultPair(vault_pair_id);
        IEntryVault(entry_vault).payout(credit_recycle_address, credit_token_address, amount);
        emit ConsumedCreditRecycled(vault_pair_id, amount);
    }

    // ─── Internal helpers ───

    function _computePicksHash(address lineup_owner, Pick[] calldata picks, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(PICKS_COMMITMENT_TYPEHASH, block.chainid, address(this), lineup_owner, picks, salt));
    }

    function _requireLineup(uint256 lineup_id) internal view returns (uint256) {
        if (lineup_id >= lineups.length) revert LineupDoesNotExist();
        return lineup_id;
    }

    function _toCoinDecimals(uint256 amount) internal view returns (uint256) {
        return amount / coin_scale;
    }

    function _isSupportedTokenType(uint8 token_type) internal pure returns (bool) {
        return token_type == TOKEN_TYPE_COIN || token_type == TOKEN_TYPE_CREDIT_TO_COIN
            || token_type == TOKEN_TYPE_CREDIT_TO_CREDIT;
    }

    function _isCreditEntry(uint8 token_type) internal pure returns (bool) {
        return token_type == TOKEN_TYPE_CREDIT_TO_COIN || token_type == TOKEN_TYPE_CREDIT_TO_CREDIT;
    }

    function _isCreditPrize(uint8 token_type) internal pure returns (bool) {
        return token_type == TOKEN_TYPE_CREDIT_TO_CREDIT;
    }

    // ─── Config / admin ───

    /// @notice Admin hold on a lineup — blocks its group from settling until resolved.
    ///         Freeze/unfreeze operate on a still-active or layer-1-settled lineup; unfreezing
    ///         returns it to ACTIVE, so a previously layer-1-settled lineup must be re-settled.
    function freezeLineup(uint256 lineup_id) external onlyAutomatedAuthority {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        // Only hold a lineup BEFORE its group settles. Freezing a group-settled lineup would
        // strand its `owed` (unfreeze returns it to ACTIVE; claimPrize needs SETTLED, claimRefund needs REFUNDED).
        bool freezable = lineup.status == STATUS_ACTIVE
            || (lineup.status == STATUS_SETTLED && groups[lineup.group_id].status == GROUP_STATUS_ACTIVE);
        if (!freezable) revert InvalidInput();
        lineup.status = STATUS_FROZEN;
        emit LineupFrozen(lineup_id);
    }

    function unfreezeLineup(uint256 lineup_id) external onlyAutomatedAuthority {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        if (lineup.status != STATUS_FROZEN) revert LineupNotFrozen();
        lineup.status = STATUS_ACTIVE;
        emit LineupUnfrozen(lineup_id);
    }

    function setAutomatedAuthority(address _automated_authority) external onlyOwner {
        if (_automated_authority == address(0)) revert InvalidInput();
        automated_authority_address = _automated_authority;
        emit AutomatedAuthorityUpdated(_automated_authority);
    }

    function setCreditRecycleAddress(address _credit_recycle_address) external onlyOwner {
        if (_credit_recycle_address == address(0)) revert InvalidInput();
        credit_recycle_address = _credit_recycle_address;
        emit CreditRecycleAddressUpdated(_credit_recycle_address);
    }

    function setTokenTypeVaultPair(uint8 token_type, uint16 vault_pair_id) external onlyOwner {
        if (!_isSupportedTokenType(token_type)) revert InvalidInput();
        (address entry_vault, address prize_treasury, bool is_active) =
            IVaultFactory(vault_factory_address).getVaultPair(vault_pair_id);
        if (entry_vault == address(0) || prize_treasury == address(0) || !is_active) revert InvalidInput();

        // Credit-prize custody must remain isolated from the coin-prize pair.
        if (token_type == TOKEN_TYPE_CREDIT_TO_CREDIT) {
            if (
                (vault_pair_configured_by_token_type[TOKEN_TYPE_COIN]
                        && vault_pair_id_by_token_type[TOKEN_TYPE_COIN] == vault_pair_id)
                    || (vault_pair_configured_by_token_type[TOKEN_TYPE_CREDIT_TO_COIN]
                        && vault_pair_id_by_token_type[TOKEN_TYPE_CREDIT_TO_COIN] == vault_pair_id)
            ) revert InvalidInput();
        } else if (
            vault_pair_configured_by_token_type[TOKEN_TYPE_CREDIT_TO_CREDIT]
                && vault_pair_id_by_token_type[TOKEN_TYPE_CREDIT_TO_CREDIT] == vault_pair_id
        ) {
            revert InvalidInput();
        }

        address entry_token = _isCreditEntry(token_type) ? credit_token_address : coin_config.token_address;
        address prize_token = _isCreditPrize(token_type) ? credit_token_address : coin_config.token_address;
        (bool entry_supported,,) = IArenaVaultPolicy(entry_vault).token_policy(entry_token);
        (bool prize_supported,,) = IArenaVaultPolicy(prize_treasury).token_policy(prize_token);
        if (!entry_supported || !prize_supported) revert InvalidInput();
        if (
            !IArenaVaultPolicy(entry_vault).whitelisted_contracts(address(this))
                || !IArenaVaultPolicy(prize_treasury).whitelisted_contracts(address(this))
        ) revert InvalidInput();
        if (
            _isCreditEntry(token_type)
                && !IArenaCreditTokenPolicy(credit_token_address).whitelisted_addresses(entry_vault)
        ) revert InvalidInput();
        if (
            _isCreditPrize(token_type)
                && !IArenaCreditTokenPolicy(credit_token_address).whitelisted_addresses(prize_treasury)
        ) revert InvalidInput();

        vault_pair_id_by_token_type[token_type] = vault_pair_id;
        vault_pair_configured_by_token_type[token_type] = true;
        emit TokenTypeVaultPairUpdated(token_type, vault_pair_id);
    }

    function setVaultFactory(address _vault_factory) external onlyOwner {
        if (_vault_factory == address(0)) revert InvalidInput();
        vault_factory_address = _vault_factory;
        emit VaultFactoryUpdated(_vault_factory);
    }

    function setMaxMultiplierCap(uint64 _max_multiplier_cap) external onlyOwner {
        max_multiplier_cap = _max_multiplier_cap;
        emit MaxMultiplierCapUpdated(_max_multiplier_cap);
    }

    /// @notice Global maximum member count. Minimum size and bucket rules are off-chain.
    function setMaxGroupSize(uint16 _max_group_size) external onlyOwner {
        if (_max_group_size > MAX_GROUP_SIZE_LIMIT) revert InvalidInput();
        max_group_size = _max_group_size;
        emit MaxGroupSizeUpdated(_max_group_size);
    }

    /// @notice Configures the pick-count admission policy checked off-chain by the authority.
    /// @dev Does not restrict settlement or refund of already-committed lineups.
    function setPickCountLimits(uint16 _min_picks_count, uint16 _max_picks_count) external onlyOwner {
        if (_min_picks_count == 0 || _min_picks_count > _max_picks_count) revert InvalidInput();
        min_picks_count = _min_picks_count;
        max_picks_count = _max_picks_count;
        emit PickCountLimitsUpdated(_min_picks_count, _max_picks_count);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Views ───

    function getLineup(uint256 lineup_id) external view returns (Lineup memory) {
        return lineups[_requireLineup(lineup_id)];
    }

    /// @notice True once a lineup has reached a terminal state: refunded, canceled, or
    ///         settled by its group. A SETTLED lineup whose group is still ACTIVE is
    ///         layer-1 settled but NOT finalized (its payout isn't determined yet).
    function isLineupFinalized(uint256 lineup_id) external view returns (bool) {
        Lineup storage lineup = lineups[_requireLineup(lineup_id)];
        uint8 status = lineup.status;
        if (status == STATUS_REFUNDED || status == STATUS_CANCELED) {
            return true;
        }
        if (status == STATUS_SETTLED) {
            return groups[lineup.group_id].status == GROUP_STATUS_SETTLED;
        }
        return false; // ACTIVE or FROZEN
    }

    function getGroup(bytes32 group_id) external view returns (Group memory) {
        if (groups[group_id].member_count == 0) revert GroupDoesNotExist();
        return groups[group_id];
    }

    function lineupsCount() external view returns (uint256) {
        return lineups.length;
    }
}
