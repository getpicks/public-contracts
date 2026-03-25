// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IEventMarketRegistry} from "./IEventMarketRegistry.sol";

interface IHotContest {
	function CREDIT_TOKEN_ADDRESS() external view returns (address);

	function drain(address to, address token, uint256 amount) external;

	function burnCredit(uint256 amount) external;

	function depositFor(address user, address token, uint256 amount) external;
}

/// @title ComboMachine - Decentralized Betting Platform with Meta-Transaction Support
/// @notice Power play betting: all non-voided picks must win for payout
/// @dev Event markets are managed by a shared EventMarketRegistry contract
/// @dev Treasury Integration:
///      - All funds are stored in HotTreasury contract, not in ComboMachine
///      - ComboMachine must be whitelisted in HotTreasury to drain funds for payouts/refunds
///      - Treasury address is immutable and supports any ERC20 token for regular bets
///      - Treasury has immutable CREDIT_TOKEN_ADDRESS that must match ComboMachine's credit token
///      - Bet placements transfer funds directly to treasury
///      - Payouts and refunds drain from treasury
///      - Credit token burns are handled by treasury.burnCredit() in a single call
/// @dev Voided Events Handling:
///      - Voided events are NOT counted as losses
///      - Multiplier is recalculated based on remaining (non-voided) picks
///      - Example: 5-pick bet with 1 voided event → treated as 4-pick bet with adjusted multiplier
///      - If remaining picks < MIN_PICKS_COUNT, bet is refunded
///      - Otherwise, payout is calculated using the multiplier for remaining picks count
/// @dev Bet Settlement Signature System:
///      - settleBet/batchSettleBet: Requires automated_authority signature with bet_id(s), picks, and signature_deadline
///      - Message format for single: keccak256(abi.encode(SETTLE_BET_TYPEHASH, chainid, contract_address, bet_id, picks, signature_deadline))
///      - Message format for batch: keccak256(abi.encode(BATCH_SETTLE_BET_TYPEHASH, chainid, contract_address, bet_ids, picks_array, signature_deadline))
///      - signature_deadline prevents replay attacks with stale signatures
///      - Anyone can submit settlements with valid automated_authority signature (gasless for automated_authority)

contract ComboMachine is Initializable, Pausable {
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;
	using SafeERC20 for IERC20;

	bytes32 internal constant SETTLE_BET_TYPEHASH = keccak256("settleBet");
	bytes32 internal constant BATCH_SETTLE_BET_TYPEHASH = keccak256("batchSettleBet");
	bytes32 internal constant PLACE_BET_TYPEHASH = keccak256("placeBet");
	bytes32 internal constant CANCEL_BET_TYPEHASH = keccak256("cancelBet");

	bytes12 internal constant VOIDED_EVENT_OUTCOME_ID = bytes12(0);

	/// @dev Bet is live and awaiting event resolution. Funds are locked.
	uint8 internal constant STATUS_ACTIVE = 0;

	/// @dev Bet is temporarily locked due to investigation or system hold.
	uint8 internal constant STATUS_FROZEN = 1;

	/// @dev Bet was canceled and the stake was fully returned to the user.
	uint8 internal constant STATUS_REFUNDED = 2;

	/// @dev Bet was invalidated and will not be settled (administrative or risk decision).
	uint8 internal constant STATUS_CANCELED = 3;

	/// @dev Stake was confiscated due to fraud, insider activity, or rule violation.
	uint8 internal constant STATUS_SEIZED = 4;

	/// @dev Bet was fully resolved and finalized. Payout (if any) was processed.
	uint8 internal constant STATUS_SETTLED = 5;

	/// @dev Internal decimals used for all bet amounts and calculations
	uint8 internal constant INTERNAL_DECIMALS = 18;

	struct MultiplierConfig {
		bool is_active;
		// with .00 precision, e.g. 250 = x2.50
		uint256[] multipliers;
	}
	// Example multiplier config:
	// is_active = true
	// 2 = x3 (we got 2 because min_picks is 2, so first index is for 2 picks)
	// 3 = x6
	// 4 = x10
	// 5 = x20
	// 6 = x37.5
	MultiplierConfig[] public multipliers;

	/// @notice Represents a single pick/selection in a bet
	/// @dev Stores the event market and outcome that the user is betting on
	struct Pick {
		bytes12 event_market_id; // ID of the event market this pick belongs to
		bytes12 outcome_id; // ID of the predicted outcome
		// bytes8 extra_data; // Reserved for future use
	}

	/// @notice Represents a bet placed by a user
	/// @dev Bet data is stored in the bets array, picks stored off-chain and verified via hash
	struct Bet {
		address owner; // Address of the bettor
		uint8 status; // Current bet status (see STATUS_* constants)
		uint8 token_type; // Token type: 0 = regular token, 1 = credit token
		uint24 multipliers_config_id; // ID of the multiplier config used for this bet
		uint48 created_at; // Timestamp when the bet was placed
		uint128 bet_size; // Amount wagered in tokens
		bytes32 picks_hash; // Keccak256 hash of the picks array for integrity
	}

	struct LazyCreateEventMarket {
		bytes12 event_market_id; // ID of the event market
		uint40 min_settlement_ts; // Minimum timestamp before settlement is allowed
	}

	/// @notice Packed configuration limits for betting
	/// @dev Packed into single struct for gas optimization
	struct BetLimits {
		uint128 min_bet_size; // Minimum bet size in INTERNAL_DECIMALS (18)
		uint128 max_bet_size; // Maximum bet size in INTERNAL_DECIMALS (18)
	}

	/// @notice Coin configuration packed into single struct
	/// @dev Packed into single storage slot (address=20 bytes + uint8=1 byte = 21 bytes)
	struct CoinConfig {
		address token_address; // Address of the ERC20 token used for betting
		uint8 decimals; // Decimals of the ERC20 token
	}

	struct ConfigLimits {
		uint16 min_picks_count;
		uint16 max_picks_count;
		uint128 max_multiplier;
	}

	/// @notice Parameters for placing a single bet in batch operations
	struct PlaceBetParams {
		Pick[] picks;
		LazyCreateEventMarket[] lazy_create_event_markets;
		uint128 bet_size;
		uint24 multipliers_config_id;
		address bet_owner;
		uint256 deadline;
		uint8 token_type; // 0 = regular token, 1 = credit token
		bytes automated_authority_signature;
		bytes owner_signature;
	}

	/// @notice Parameters for canceling a single bet
	struct CancelBetParams {
		uint256 bet_id;
		Pick[] picks;
		address bet_owner;
		uint256 deadline;
		bytes owner_signature;
		bytes automated_authority_signature;
	}

	/// @notice Packed coin configuration
	CoinConfig public coin_config;

	/// @notice Address authorized to settle event outcomes and sign bet approvals
	address public automated_authority_address;

	address public owner;

	/// @notice Address of the credit token contract for credit-based betting
	address public credit_token_address;

	/// @notice Address of the hot treasury contract
	address public hot_treasury_address;

	ConfigLimits public config_limits;

	/// @notice Mapping of addresses authorized to perform compliance actions
	mapping(address => bool) public compliance_officers;

	/// @notice Packed betting limits configuration
	/// @dev min_bet_size is in INTERNAL_DECIMALS (18). Examples:
	///      - For USDC (6 decimals): 1000000000000000 = 0.001 USDC
	///      - For USDT (6 decimals): 1000000000000000 = 0.001 USDT
	///      - For DAI (18 decimals): 1000000000000000 = 0.001 DAI
	///      - Must be divisible by 10^(18 - token_decimals) to avoid precision loss
	BetLimits public bet_limits;

	/// @notice Mapping of wallets that are blocked from placing bets
	mapping(address => bool) public blacklisted_wallets;

	/// @notice Array storing all bets in the system
	Bet[] public bets;

	/// @notice Nonce for each wallet to prevent replay attacks
	mapping(address => uint256) public wallet_nonce;

	/// @notice Address of the shared event market registry
	address public event_market_registry_address;

	/// @notice Cancel fee in basis points (e.g. 1000 = 10%)
	uint16 public cancel_fee_bps;

	/// @dev bet_size is in INTERNAL_DECIMALS (18)
	event BetPlaced(
		address indexed owner_address,
		uint256 indexed bet_id,
		uint128 bet_size,
		uint24 multipliers_config_id,
		uint8 token_type,
		uint256 wallet_nonce,
		Pick[] picks
	);

	/// @dev payout is in INTERNAL_DECIMALS (18)
	event BetSettled(address indexed owner_address, uint256 indexed bet_id, bool won, uint256 payout);

	event BetFrozen(address indexed owner_address, uint256 indexed bet_id);

	event BetRefunded(address indexed owner_address, uint256 indexed bet_id);

	event BetCanceledByUser(address indexed owner_address, uint256 indexed bet_id, uint128 refund_amount, uint128 fee_amount, uint16 fee_bps);

	event BetSeized(address indexed owner_address, uint256 indexed bet_id);

	event BetActivated(address indexed owner_address, uint256 indexed bet_id);

	event BetMultiplierConfigIdChanged(
		address indexed owner_address,
		uint256 indexed bet_id,
		uint24 old_config_id,
		uint24 new_config_id
	);

	event ConfigurationUpdated(
		address automated_authority_address,
		address hot_treasury_address,
		uint128 min_bet_size,
		uint128 max_bet_size,
		uint16 cancel_fee_bps
	);

	event MultiplierConfigAdded(uint24 indexed config_id, uint256[] multipliers);

	event MultiplierConfigUpdated(uint24 indexed config_id, uint256[] multipliers, bool is_active);

	event ComplianceOfficerAdded(address indexed officer);

	event ComplianceOfficerRemoved(address indexed officer);

	event WalletBlacklisted(address indexed wallet);

	event WalletUnblacklisted(address indexed wallet);

	event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

	error InvalidSignature();
	error BetDoesNotExist();
	error InvalidBetSize();
	error InvalidMultiplier();
	error InvalidPicksCount();
	error InvalidMultiplierArrayLength();
	error InvalidInput();
	error Unauthorized();
	error InvalidStatus();
	error BetNotActive();
	error EventMarketsNotSettled();
	error BetSizePrecisionLoss();
	error SignatureExpired();
	error CancelWindowClosed();
	error OwnableUnauthorizedAccount(address account);
	error OwnableInvalidOwner(address owner);

	modifier onlyOwner() {
		_checkOwner();
		_;
	}

	/// @dev Modifier to restrict access to compliance officers only
	modifier onlyComplianceOfficer() {
		if (!compliance_officers[msg.sender]) revert Unauthorized();
		_;
	}

	constructor() {
		_disableInitializers();
	}

	/// @notice Initializes the betting contract with required addresses
	/// @param _coin_address Address of the ERC20 token used for betting
	/// @param _automated_authority_address Address authorized to sign bet approvals
	/// @param _credit_token_address Address of the credit token contract
	/// @param _hot_treasury_address Address of the hot treasury contract
	/// @param _event_market_registry_address Address of the shared event market registry
	/// @param initial_owner Address that will own the contract
	/// @param _min_picks_count Minimum number of picks required per bet
	/// @param _max_picks_count Maximum number of picks allowed per bet
	/// @param _max_multiplier Maximum allowed multiplier value (with .00 precision, e.g. 10000 = x100.00)
	function initialize(
		address _coin_address,
		address _automated_authority_address,
		address _credit_token_address,
		address _hot_treasury_address,
		address _event_market_registry_address,
		address initial_owner,
		uint16 _min_picks_count,
		uint16 _max_picks_count,
		uint256 _max_multiplier
	) external initializer {
		// Validate owner address
		if (initial_owner == address(0)) revert InvalidInput();

		// Validate picks count
		if (_min_picks_count == 0 || _max_picks_count == 0) revert InvalidInput();
		if (_min_picks_count > _max_picks_count) revert InvalidPicksCount();

		// Validate max multiplier
		if (_max_multiplier == 0) revert InvalidInput();

		// Set immutable picks count values
		if (_max_multiplier > type(uint128).max) revert InvalidInput();
		config_limits = ConfigLimits({
			min_picks_count: _min_picks_count,
			max_picks_count: _max_picks_count,
			// forge-lint: disable-next-line(unsafe-typecast)
			max_multiplier: uint128(_max_multiplier)
		});

		_initializeAddresses(
			_coin_address,
			_automated_authority_address,
			_credit_token_address,
			_hot_treasury_address,
			_event_market_registry_address
		);

		bet_limits = BetLimits({
			min_bet_size: 1000000000000000, // 0.001 tokens (18 decimals)
			max_bet_size: 100_000 * 1e18 // 100,000 tokens (18 decimals)
		});
		_transferOwnership(initial_owner);
	}

	/// @notice Internal helper to validate and set address-based state variables
	/// @dev Extracted from initialize() to avoid stack-too-deep
	function _initializeAddresses(
		address _coin_address,
		address _automated_authority_address,
		address _credit_token_address,
		address _hot_treasury_address,
		address _event_market_registry_address
	) internal {
		// Fetch and validate coin decimals
		uint8 _decimals = IERC20Metadata(_coin_address).decimals();
		if (_decimals > 18) revert InvalidInput();
		coin_config = CoinConfig({token_address: _coin_address, decimals: _decimals});

		if (_automated_authority_address == address(0)) revert InvalidInput();
		if (_credit_token_address == address(0)) revert InvalidInput();

		// Validate credit token has exactly 18 decimals
		uint8 _credit_decimals = IERC20Metadata(_credit_token_address).decimals();
		if (_credit_decimals != INTERNAL_DECIMALS) revert InvalidInput();

		// Validate hot treasury address
		if (_hot_treasury_address == address(0)) revert InvalidInput();

		// Verify treasury credit token matches this contract's credit token
		if (IHotContest(_hot_treasury_address).CREDIT_TOKEN_ADDRESS() != _credit_token_address)
			revert InvalidInput();

		if (_event_market_registry_address == address(0)) revert InvalidInput();

		automated_authority_address = _automated_authority_address;
		credit_token_address = _credit_token_address;
		hot_treasury_address = _hot_treasury_address;
		event_market_registry_address = _event_market_registry_address;

		// Approve treasury to pull tokens from this contract
		IERC20(_coin_address).approve(_hot_treasury_address, type(uint256).max);
		IERC20(_credit_token_address).approve(_hot_treasury_address, type(uint256).max);
	}

	/// @notice Places a new bet with multiple picks (parlay/accumulator bet)
	/// @dev Requires picks & lazy_create_event_markets to be sorted by event_market_id ascending
	/// @dev event_market_id in picks & lazy_create_event_markets cannot be zero
	/// @dev Validates signature from guard, creates bet, stores picks, and registers event markets
	/// @param params Struct containing all bet placement parameters
	function placeBet(PlaceBetParams calldata params) external whenNotPaused {
		_placeBet(params);
	}

	/// @notice Internal function to create bet message hash for signature verification
	/// @dev Reduces stack depth in _placeBet by isolating hash creation
	function _createBetMessageHash(
		Pick[] calldata picks,
		LazyCreateEventMarket[] calldata lazy_create_event_markets,
		uint128 bet_size,
		uint24 multipliers_config_id,
		address bet_owner,
		uint256 deadline,
		uint256 nonce,
		uint8 token_type
	) internal view returns (bytes32) {
		return
			keccak256(
				abi.encode(
					PLACE_BET_TYPEHASH,
					block.chainid,
					address(this),
					bet_owner,
					picks,
					lazy_create_event_markets,
					bet_size,
					multipliers_config_id,
					deadline,
					nonce,
					token_type
				)
			);
	}

	/// @notice Internal function to place a bet
	/// @dev Contains core bet placement logic, called by both placeBet and batchPlaceBet
	/// @param params Struct containing all bet placement parameters
	function _placeBet(PlaceBetParams calldata params) internal {
		ConfigLimits memory limits = config_limits;

		// Validate bet owner
		if (params.bet_owner == address(0)) revert InvalidInput();

		// Check deadline
		if (block.timestamp > params.deadline) revert InvalidInput();

		// Check if bet owner is blacklisted
		if (blacklisted_wallets[params.bet_owner]) revert Unauthorized();

		// Validate token type
		if (params.token_type > 1) revert InvalidInput();

		// Validate picks array
		if (params.lazy_create_event_markets.length != params.picks.length) revert InvalidInput();
		if (params.bet_size < bet_limits.min_bet_size || params.bet_size > bet_limits.max_bet_size) revert InvalidBetSize();
		if (
			params.picks.length < limits.min_picks_count || params.picks.length > limits.max_picks_count
		) revert InvalidPicksCount();

		// Validate multiplier config and get multiplier
		if (params.multipliers_config_id >= multipliers.length) revert InvalidMultiplier();
		MultiplierConfig storage config = multipliers[params.multipliers_config_id];
		if (!config.is_active) revert InvalidMultiplier();

		// Validate picks count is within multiplier config range
		uint256 multiplier_index = params.picks.length - limits.min_picks_count;
		if (multiplier_index >= config.multipliers.length) revert InvalidPicksCount();

		// Verify signatures
		uint256 current_nonce = wallet_nonce[params.bet_owner];
		bytes32 message_hash = _createBetMessageHash(
			params.picks,
			params.lazy_create_event_markets,
			params.bet_size,
			params.multipliers_config_id,
			params.bet_owner,
			params.deadline,
			current_nonce,
			params.token_type
		);
		_verifyOwnerSignature(message_hash, params.owner_signature, params.bet_owner);
		_verifyAutomatedAuthoritySignature(message_hash, params.automated_authority_signature);

		CoinConfig memory coin_cfg = coin_config;
		// Transfer funds from bet owner to treasury
		if (params.token_type == 0) {
			// Regular token: convert from internal decimals to token decimals
			uint256 coin_amount = _betSizeToCoinAmountWithDecimals(params.bet_size, coin_cfg.decimals);

			// Validate minimum amount in token decimals (at least 1 unit)
			// Example: For USDC (6 decimals), coin_amount must be >= 1 (0.000001 USDC)
			if (coin_amount == 0) revert InvalidBetSize();

			// Validate no precision loss during conversion
			// Convert back to internal decimals and ensure it matches original bet_size
			// This prevents bets that would lose value during decimal conversion
			uint256 converted_back = _coinAmountToBetSizeWithDecimals(coin_amount, coin_cfg.decimals);
			if (converted_back != params.bet_size) revert BetSizePrecisionLoss();

			IHotContest(hot_treasury_address).depositFor(
				params.bet_owner,
				coin_cfg.token_address,
				coin_amount
			);
		} else {
			// Credit token: already in 18 decimals, no conversion needed
			if (params.bet_size == 0) revert InvalidBetSize();
			IHotContest(hot_treasury_address).depositFor(
				params.bet_owner,
				credit_token_address,
				params.bet_size
			);
		}

		// Create bet and process event markets
		uint256 bet_id = _insertNewBet(
			params.bet_owner,
			params.bet_size,
			params.multipliers_config_id,
			params.token_type,
			params.picks
		);
		_processEventMarkets(params.picks, params.lazy_create_event_markets);

		wallet_nonce[params.bet_owner] = current_nonce + 1;

		emit BetPlaced(
			params.bet_owner,
			bet_id,
			params.bet_size,
			params.multipliers_config_id,
			params.token_type,
			current_nonce,
			params.picks
		);
	}

	/// @notice Places multiple bets in a single transaction
	/// @dev Loops through bet_params array and calls _placeBet for each
	/// @param bet_params Array of bet parameters
	function batchPlaceBet(PlaceBetParams[] calldata bet_params) external whenNotPaused {
		uint256 batch_size = bet_params.length;
		if (batch_size == 0) revert InvalidInput();

		for (uint256 i = 0; i < batch_size; ++i) {
			_placeBet(bet_params[i]);
		}
	}

	/// @notice Internal function to process and validate picks and event markets
	/// @dev Creates new event markets in the registry if needed, validates existing ones
	/// @param picks Array of picks
	/// @param lazy_create_event_markets Array of event market creation data
	function _processEventMarkets(
		Pick[] calldata picks,
		LazyCreateEventMarket[] calldata lazy_create_event_markets
	) internal {
		IEventMarketRegistry registry = IEventMarketRegistry(event_market_registry_address);
		uint96 last_event_market_id = 0;
		uint256 picks_length = picks.length;

		for (uint256 i = 0; i < picks_length; ++i) {
			bytes12 event_market_id = lazy_create_event_markets[i].event_market_id;
			uint96 event_market_id_numeric = uint96(event_market_id);

			// preventing duplicates of event_markets in the bet
			if (last_event_market_id < event_market_id_numeric) {
				last_event_market_id = event_market_id_numeric;
			} else {
				revert InvalidInput();
			}

			if (event_market_id == bytes12(0)) revert InvalidInput();

			if (event_market_id != picks[i].event_market_id) {
				revert InvalidInput();
			}

			registry.ensureExists(event_market_id, lazy_create_event_markets[i].min_settlement_ts);
		}
	}

	/// @notice Internal function to verify automated_authority signature for bet placement
	/// @dev Validates that the bet was authorized by the automated_authority_address
	/// @param message_hash Hash of the bet parameters
	/// @param automated_authority_signature Signature from automated_authority_address
	function _verifyAutomatedAuthoritySignature(
		bytes32 message_hash,
		bytes calldata automated_authority_signature
	) internal view {
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();
	}

	/// @notice Internal function to verify owner signature for bet placement
	/// @dev Validates that the bet was signed by the bet owner
	/// @param message_hash Hash of the bet parameters
	/// @param owner_signature Signature from bet owner
	/// @param expected_signer Expected address of the signer (bet owner)
	function _verifyOwnerSignature(
		bytes32 message_hash,
		bytes calldata owner_signature,
		address expected_signer
	) internal pure {
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(owner_signature);

		if (signer != expected_signer) revert InvalidSignature();
	}

	/// @notice Internal function to create and insert a new bet
	/// @dev Returns the bet ID (index in bets array). Calculates picks_hash internally.
	/// @param owner_address Address of the bettor
	/// @param bet_size_internal Bet size in internal decimals (18)
	/// @param multipliers_config_id ID of the multiplier config used for this bet
	/// @param picks Array of picks to hash and store
	/// @return bet_id The ID of the newly created bet
	function _insertNewBet(
		address owner_address,
		uint128 bet_size_internal,
		uint24 multipliers_config_id,
		uint8 token_type,
		Pick[] calldata picks
	) internal returns (uint256 bet_id) {
		bytes32 picks_hash = keccak256(abi.encode(picks));
		bet_id = bets.length;
		bets.push(
			Bet({
				owner: owner_address,
				status: STATUS_ACTIVE,
				token_type: token_type,
				multipliers_config_id: multipliers_config_id,
				created_at: uint48(block.timestamp),
				bet_size: bet_size_internal,
				picks_hash: picks_hash
			})
		);
	}

	/// @notice Converts coin amount to bet size (internal decimals 18)
	/// @dev Currently unused - reserved for future deposit/top-up functionality
	/// @param amount Amount in coin decimals
	/// @return Bet size in internal decimals (18)
	function _coinAmountToBetSize(uint256 amount) internal view returns (uint256) {
		uint8 coin_decimals = coin_config.decimals;
		return _coinAmountToBetSizeWithDecimals(amount, coin_decimals);
	}

	/// @notice Converts bet size to coin amount (coin decimals)
	/// @dev Scales down if coin has fewer decimals, no change if equal
	/// @param amount Bet size in internal decimals (18)
	/// @return Amount in coin decimals
	function _betSizeToCoinAmount(uint256 amount) internal view returns (uint256) {
		uint8 coin_decimals = coin_config.decimals;
		return _betSizeToCoinAmountWithDecimals(amount, coin_decimals);
	}

	function _coinAmountToBetSizeWithDecimals(
		uint256 amount,
		uint8 coin_decimals
	) internal pure returns (uint256) {
		if (coin_decimals == INTERNAL_DECIMALS) return amount;
		return amount * (10 ** (INTERNAL_DECIMALS - coin_decimals));
	}

	function _betSizeToCoinAmountWithDecimals(
		uint256 amount,
		uint8 coin_decimals
	) internal pure returns (uint256) {
		if (coin_decimals == INTERNAL_DECIMALS) return amount;
		return amount / (10 ** (INTERNAL_DECIMALS - coin_decimals));
	}

	/// @notice Internal function to withdraw/refund bet funds to the bettor
	/// @dev For real token bets, drains USDC from treasury. For credit bets, returns credit tokens.
	/// @param wallet_address Address to send the funds to
	/// @param bet_size Amount to refund in internal decimals (18 dec)
	/// @param token_type Token type (0 = real token, 1 = credit)
	function _withdrawBetFunds(address wallet_address, uint128 bet_size, uint8 token_type) internal {
		if (token_type == 0) {
			CoinConfig storage coin_cfg = coin_config;
			uint256 amount_in_coin_decimals = _betSizeToCoinAmountWithDecimals(bet_size, coin_cfg.decimals);
			IHotContest(hot_treasury_address).drain(wallet_address, coin_cfg.token_address, amount_in_coin_decimals);
		} else {
			// Credit bets: return credit tokens directly (bet_size is already in 18 decimals)
			IHotContest(hot_treasury_address).drain(wallet_address, credit_token_address, bet_size);
		}
	}

	/// @notice Settles a bet after all its event markets have been resolved
	/// @dev Can be called by anyone with a valid automated_authority signature
	/// @dev Checks all picks against winning outcomes, determines if bet won, and processes payout
	/// @dev Voided events are excluded from settlement calculation - multiplier adjusts to remaining picks
	/// @dev Example: 5-pick bet with 1 voided event becomes 4-pick bet with adjusted multiplier
	/// @param bet_id Index of the bet in the bets array
	/// @param picks Array of picks to verify and settle (must match picks_hash from bet placement)
	/// @param signature_deadline Timestamp after which the signature expires
	/// @param automated_authority_signature Signature from automated_authority_address
	function settleBet(
		uint256 bet_id,
		Pick[] calldata picks,
		uint256 signature_deadline,
		bytes calldata automated_authority_signature
	) external whenNotPaused {
		if (block.timestamp > signature_deadline) revert SignatureExpired();

		// Create message hash and verify automated_authority signature
		bytes32 message_hash = keccak256(
			abi.encode(
				SETTLE_BET_TYPEHASH,
				block.chainid,
				address(this),
				bet_id,
				picks,
				signature_deadline
			)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();

		_settleBet(bet_id, picks);
	}

	/// @notice Internal function to settle a bet
	/// @dev Contains core bet settlement logic, called by both settleBet and batchSettleBet
	/// @dev If events are voided, multiplier is recalculated based on remaining picks
	/// @dev If too many events are voided (remaining < MIN_PICKS_COUNT), bet is refunded
	function _settleBet(uint256 bet_id, Pick[] calldata picks) internal {
		ConfigLimits memory limits = config_limits;
		CoinConfig memory coin_cfg = coin_config;

		if (bet_id >= bets.length) revert BetDoesNotExist();

		Bet storage bet = bets[bet_id];

		if (bet.status != STATUS_ACTIVE) revert BetNotActive();

		// Verify picks match the stored hash
		if (keccak256(abi.encode(picks)) != bet.picks_hash) revert InvalidInput();

		IEventMarketRegistry registry = IEventMarketRegistry(event_market_registry_address);
		bool all_events_settled = true;
		bool all_non_voided_picks_won = true;
		uint256 voided_count = 0;

		uint256 picks_count = picks.length;
		for (uint256 i = 0; i < picks_count; ++i) {
			Pick calldata pick = picks[i];
			IEventMarketRegistry.EventMarket memory event_market = registry.getEventMarket(pick.event_market_id);

			if (!event_market.is_settled) {
				all_events_settled = false;
				break;
			}

			// Count voided events but don't treat as loss
			if (event_market.winning_outcome_id == VOIDED_EVENT_OUTCOME_ID) {
				voided_count++;
				continue;
			}

			if (pick.outcome_id != event_market.winning_outcome_id) {
				all_non_voided_picks_won = false;
			}
		}

		if (!all_events_settled) revert EventMarketsNotSettled();

		// Calculate remaining picks after voided events
		// Example: 5 picks with 1 voided = 4 remaining picks
		uint256 remaining_picks = picks_count - voided_count;

		// Retrieve multiplier config
		if (bet.multipliers_config_id >= multipliers.length) revert InvalidMultiplier();
		MultiplierConfig storage config = multipliers[bet.multipliers_config_id];

		// Refund if too many picks are voided (including all voided where remaining = 0)
		if (remaining_picks < limits.min_picks_count) {
			bet.status = STATUS_REFUNDED;
			_withdrawBetFunds(bet.owner, bet.bet_size, bet.token_type);
			emit BetRefunded(bet.owner, bet_id);
			return;
		}

		bet.status = STATUS_SETTLED;

		// If bet was placed with credit tokens, burn them from treasury (regardless of win/loss)
		// Credit tokens always have 18 decimals, same as bet_size, so no conversion needed
		if (bet.token_type == 1) {
			// Burn credit tokens directly from treasury
			IHotContest(hot_treasury_address).burnCredit(bet.bet_size);
		}

		uint256 payout = 0;

		// Calculate and transfer payout if all non-voided picks won
		if (all_non_voided_picks_won) {
			// Calculate multiplier based on remaining picks (after voided events removed)
			// Example: If bet had 5 picks, 1 voided, and MIN_PICKS_COUNT = 2:
			//   remaining_picks = 4, multiplier_index = 4 - 2 = 2
			//   Uses config.multipliers[2] which is the multiplier for 4 picks
			uint256 multiplier_index = remaining_picks - limits.min_picks_count;
			if (multiplier_index >= config.multipliers.length) revert InvalidPicksCount();

			// Calculate payout in internal decimals: bet_size * multiplier / 100
			// Example: 1000 wei * 250 / 100 = 2500 wei (2.5x payout)
			payout = (uint256(bet.bet_size) * uint256(config.multipliers[multiplier_index])) / 100;

			// Convert to coin decimals and drain regular tokens from treasury to the winner
			// NOTE: Payouts are ALWAYS in regular tokens, regardless of token_type used for bet
			uint256 payout_in_coin_decimals = _betSizeToCoinAmountWithDecimals(payout, coin_cfg.decimals);
			IHotContest(hot_treasury_address).drain(bet.owner, coin_cfg.token_address, payout_in_coin_decimals);
		}

		emit BetSettled(bet.owner, bet_id, all_non_voided_picks_won, payout);
	}

	/// @notice Settles multiple bets in a single transaction
	/// @dev Can be called by anyone with a valid automated_authority signature
	/// @dev Loops through bet_ids and their corresponding picks arrays, calls _settleBet for each
	/// @param bet_ids Array of bet IDs to settle
	/// @param picks_array Array of picks arrays, one for each bet_id
	/// @param signature_deadline Timestamp after which the signature expires
	/// @param automated_authority_signature Signature from automated_authority_address
	function batchSettleBet(
		uint256[] calldata bet_ids,
		Pick[][] calldata picks_array,
		uint256 signature_deadline,
		bytes calldata automated_authority_signature
	) external whenNotPaused {
		uint256 batch_size = bet_ids.length;
		if (batch_size == 0) revert InvalidInput();
		if (batch_size != picks_array.length) revert InvalidInput();
		if (block.timestamp > signature_deadline) revert SignatureExpired();

		// Create message hash and verify automated_authority signature
		bytes32 message_hash = keccak256(
			abi.encode(
				BATCH_SETTLE_BET_TYPEHASH,
				block.chainid,
				address(this),
				bet_ids,
				picks_array,
				signature_deadline
			)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();

		for (uint256 i = 0; i < batch_size; ++i) {
			_settleBet(bet_ids[i], picks_array[i]);
		}
	}

	/// @notice Allows a user to cancel their own active bet before any event reaches settlement time
	/// @dev Requires both owner and automated authority signatures. Deducts cancel_fee_bps from bet_size, refunds the rest.
	/// @param params Struct containing all cancel parameters including signatures
	function cancelBet(CancelBetParams calldata params) external whenNotPaused {
		_verifySignaturesAndCancelBet(params);
	}

	/// @notice Cancels multiple bets in a single transaction
	/// @dev Each cancel is independently signed by its owner and the automated authority
	/// @param cancel_params Array of cancel parameters, one for each bet
	function batchCancelBet(CancelBetParams[] calldata cancel_params) external whenNotPaused {
		uint256 batch_size = cancel_params.length;
		if (batch_size == 0) revert InvalidInput();

		for (uint256 i = 0; i < batch_size; ++i) {
			_verifySignaturesAndCancelBet(cancel_params[i]);
		}
	}

	/// @notice Internal function to verify cancel signatures and execute the cancel
	function _verifySignaturesAndCancelBet(CancelBetParams calldata params) internal {
		if (block.timestamp > params.deadline) revert SignatureExpired();

		uint256 current_nonce = wallet_nonce[params.bet_owner];
		bytes32 message_hash = keccak256(
			abi.encode(
				CANCEL_BET_TYPEHASH,
				block.chainid,
				address(this),
				params.bet_owner,
				params.bet_id,
				params.picks,
				params.deadline,
				current_nonce
			)
		);
		_verifyOwnerSignature(message_hash, params.owner_signature, params.bet_owner);
		_verifyAutomatedAuthoritySignature(message_hash, params.automated_authority_signature);

		wallet_nonce[params.bet_owner] = current_nonce + 1;

		_cancelBet(params.bet_id, params.picks, params.bet_owner);
	}

	/// @notice Internal function to cancel a bet
	function _cancelBet(uint256 bet_id, Pick[] calldata picks, address bet_owner) internal {
		if (bet_id >= bets.length) revert BetDoesNotExist();

		Bet storage bet = bets[bet_id];

		if (bet.status != STATUS_ACTIVE) revert BetNotActive();
		if (bet.owner != bet_owner) revert Unauthorized();
		if (keccak256(abi.encode(picks)) != bet.picks_hash) revert InvalidInput();

		// Check no event has reached min_settlement_ts
		IEventMarketRegistry registry = IEventMarketRegistry(event_market_registry_address);
		uint256 picks_count = picks.length;
		for (uint256 i = 0; i < picks_count; ++i) {
			IEventMarketRegistry.EventMarket memory em = registry.getEventMarket(picks[i].event_market_id);
			if (block.timestamp >= em.min_settlement_ts) revert CancelWindowClosed();
		}

		bet.status = STATUS_CANCELED;

		uint128 fee = (bet.bet_size * cancel_fee_bps) / 10000;
		uint128 refund = bet.bet_size - fee;

		// Fee stays in treasury, only refund the net amount
		_withdrawBetFunds(bet.owner, refund, bet.token_type);

		emit BetCanceledByUser(bet.owner, bet_id, refund, fee, cancel_fee_bps);
	}

	/// @notice Performs administrative enforcement action on a bet (activate, freeze, refund, or seize)
	/// @dev Can only be called by compliance officer. Refunds automatically return funds to bettor.
	/// @param bet_id Index of the bet in the bets array
	/// @param new_status New administrative status (ACTIVE=0, FROZEN=1, REFUNDED=2, SEIZED=4)
	function enforceBetStatus(uint256 bet_id, uint8 new_status) external onlyComplianceOfficer {
		if (bet_id >= bets.length) revert BetDoesNotExist();

		Bet storage bet = bets[bet_id];

		if (new_status == STATUS_ACTIVE) {
			if (bet.status != STATUS_FROZEN) revert InvalidStatus();

			bet.status = STATUS_ACTIVE;
			emit BetActivated(bet.owner, bet_id);
		} else if (new_status == STATUS_FROZEN) {
			if (bet.status != STATUS_ACTIVE) revert BetNotActive();

			bet.status = STATUS_FROZEN;
			emit BetFrozen(bet.owner, bet_id);
		} else if (new_status == STATUS_REFUNDED) {
			if (bet.status != STATUS_ACTIVE && bet.status != STATUS_FROZEN) revert BetNotActive();

			bet.status = STATUS_REFUNDED;
			_withdrawBetFunds(bet.owner, bet.bet_size, bet.token_type);
			emit BetRefunded(bet.owner, bet_id);
		} else if (new_status == STATUS_SEIZED) {
			if (bet.status != STATUS_ACTIVE && bet.status != STATUS_FROZEN) revert BetNotActive();

			bet.status = STATUS_SEIZED;
			// Seized funds stay in treasury, no withdrawal needed
			emit BetSeized(bet.owner, bet_id);
		} else {
			revert InvalidStatus();
		}
	}

	/// @notice Changes the multiplier config ID for a bet
	/// @dev Can only be called by compliance officers. Only works on active or frozen bets.
	/// @param bet_id Index of the bet in the bets array
	/// @param new_config_id New multiplier config ID
	function enforceBetMultiplierConfigId(
		uint256 bet_id,
		uint24 new_config_id
	) external onlyComplianceOfficer {
		if (bet_id >= bets.length) revert BetDoesNotExist();
		if (new_config_id >= multipliers.length) revert InvalidMultiplier();

		Bet storage bet = bets[bet_id];

		// Only allow changing config for active or frozen bets
		if (bet.status != STATUS_ACTIVE && bet.status != STATUS_FROZEN) revert InvalidStatus();

		uint24 old_config_id = bet.multipliers_config_id;
		bet.multipliers_config_id = new_config_id;

		emit BetMultiplierConfigIdChanged(bet.owner, bet_id, old_config_id, new_config_id);
	}

	/// @notice Adds a wallet to the blacklist, preventing it from placing bets
	/// @dev Can only be called by compliance officers
	/// @param wallet Address of the wallet to blacklist
	function addToBlacklist(address wallet) external onlyComplianceOfficer {
		if (wallet == address(0)) revert InvalidInput();
		blacklisted_wallets[wallet] = true;
		emit WalletBlacklisted(wallet);
	}

	/// @notice Removes a wallet from the blacklist, allowing it to place bets again
	/// @dev Can only be called by compliance officers
	/// @param wallet Address of the wallet to unblacklist
	function removeFromBlacklist(address wallet) external onlyComplianceOfficer {
		blacklisted_wallets[wallet] = false;
		emit WalletUnblacklisted(wallet);
	}

	/// @notice Updates contract configuration parameters
	/// @dev Can only be called by contract owner. Use address(0) or 0 to skip updating a parameter.
	/// @param new_automated_authority_address New automated_authority address (or address(0) to skip)
	/// @param new_hot_treasury_address New hot treasury address (or address(0) to skip)
	/// @param new_min_bet_size New minimum bet size (or 0 to skip)
	/// @param new_max_bet_size New maximum bet size (or 0 to skip)
	/// @param new_cancel_fee_bps New cancel fee in basis points (or type(uint16).max to skip)
	function updateConfiguration(
		address new_automated_authority_address,
		address new_hot_treasury_address,
		uint128 new_min_bet_size,
		uint128 new_max_bet_size,
		uint16 new_cancel_fee_bps
	) external onlyOwner {
		// Update automated_authority address if provided
		if (new_automated_authority_address != address(0)) {
			automated_authority_address = new_automated_authority_address;
		}

		// Update hot treasury address if provided
		if (new_hot_treasury_address != address(0)) {
			hot_treasury_address = new_hot_treasury_address;
		}

		// Update min bet size if provided
		if (new_min_bet_size > 0) {
			bet_limits.min_bet_size = new_min_bet_size;
		}

		// Update max bet size if provided
		if (new_max_bet_size > 0) {
			bet_limits.max_bet_size = new_max_bet_size;
		}

		// Update cancel fee if provided (type(uint16).max = skip)
		if (new_cancel_fee_bps != type(uint16).max) {
			cancel_fee_bps = new_cancel_fee_bps;
		}

		emit ConfigurationUpdated(
			automated_authority_address,
			hot_treasury_address,
			bet_limits.min_bet_size,
			bet_limits.max_bet_size,
			cancel_fee_bps
		);
	}

	/// @notice Adds a new multiplier configuration
	/// @dev Can only be called by contract owner
	/// @dev Multipliers array length must be exactly: MAX_PICKS_COUNT - (MIN_PICKS_COUNT - 1)
	/// @param multipliers_array Array of multipliers (with .00 precision, e.g. 250 = x2.50)
	function addMultiplierConfig(uint256[] calldata multipliers_array) external onlyOwner {
		ConfigLimits memory limits = config_limits;

		// Validate multipliers array length
		uint256 expected_length = uint256(limits.max_picks_count) -
			(uint256(limits.min_picks_count) - 1);
		if (multipliers_array.length != expected_length) revert InvalidMultiplierArrayLength();
		if (multipliers.length > type(uint24).max) revert InvalidInput();

		// Validate multipliers are within valid range
		for (uint256 i = 0; i < multipliers_array.length; ++i) {
			if (multipliers_array[i] == 0) revert InvalidMultiplier();
			if (multipliers_array[i] > uint256(limits.max_multiplier)) revert InvalidMultiplier();
		}

		uint24 config_id = uint24(multipliers.length);
		multipliers.push(MultiplierConfig({is_active: true, multipliers: multipliers_array}));

		emit MultiplierConfigAdded(config_id, multipliers_array);
	}

	/// @notice Updates an existing multiplier configuration
	/// @notice Can be updated midgame it it is totally fine, as it can be done only by the owner
	/// @dev Can only be called by contract owner
	/// @dev Multipliers array length must be exactly: MAX_PICKS_COUNT - (MIN_PICKS_COUNT - 1)
	/// @dev We know this can affect active bets AND THIS IS OK, owner will be multisig so no issues
	/// @param config_id ID of the config to update
	/// @param multipliers_array New array of multipliers
	/// @param is_active Whether the config should be active
	function updateMultiplierConfig(
		uint24 config_id,
		uint256[] calldata multipliers_array,
		bool is_active
	) external onlyOwner {
		ConfigLimits memory limits = config_limits;

		if (config_id >= multipliers.length) revert InvalidInput();

		// Validate multipliers array length
		uint256 expected_length = uint256(limits.max_picks_count) -
			(uint256(limits.min_picks_count) - 1);
		if (multipliers_array.length != expected_length) revert InvalidMultiplierArrayLength();

		// Validate multipliers are within valid range
		for (uint256 i = 0; i < multipliers_array.length; ++i) {
			if (multipliers_array[i] == 0) revert InvalidMultiplier();
			if (multipliers_array[i] > uint256(limits.max_multiplier)) revert InvalidMultiplier();
		}

		MultiplierConfig storage config = multipliers[config_id];
		config.multipliers = multipliers_array;
		config.is_active = is_active;

		emit MultiplierConfigUpdated(config_id, multipliers_array, is_active);
	}

	/// @notice Gets the total number of multiplier configurations
	/// @return Total count of multiplier configs
	function getMultiplierConfigsCount() external view returns (uint256) {
		return multipliers.length;
	}

	function _checkOwner() internal view {
		if (owner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
	}

	function renounceOwnership() external onlyOwner {
		_transferOwnership(address(0));
	}

	function transferOwnership(address new_owner) external onlyOwner {
		if (new_owner == address(0)) revert OwnableInvalidOwner(address(0));
		_transferOwnership(new_owner);
	}

	function _transferOwnership(address new_owner) internal {
		address old_owner = owner;
		owner = new_owner;
		emit OwnershipTransferred(old_owner, new_owner);
	}

	/// @notice Pauses the contract, preventing bet placement and settlement
	/// @dev Can only be called by contract owner
	function pause() external onlyOwner {
		_pause();
	}

	/// @notice Unpauses the contract, resuming normal operations
	/// @dev Can only be called by contract owner
	function unpause() external onlyOwner {
		_unpause();
	}

	/// @notice Adds a new compliance officer
	/// @dev Can only be called by contract owner
	/// @param officer Address of the compliance officer to add
	function addComplianceOfficer(address officer) external onlyOwner {
		if (officer == address(0)) revert InvalidInput();
		compliance_officers[officer] = true;
		emit ComplianceOfficerAdded(officer);
	}

	/// @notice Removes a compliance officer
	/// @dev Can only be called by contract owner
	/// @param officer Address of the compliance officer to remove
	function removeComplianceOfficer(address officer) external onlyOwner {
		compliance_officers[officer] = false;
		emit ComplianceOfficerRemoved(officer);
	}

	/// @notice Gets the total number of bets created in the system
	/// @dev Returns the length of the bets array
	/// @return Total count of bets (both active and finalized)
	function getTotalBetsCount() external view returns (uint256) {
		return bets.length;
	}

	/// @notice Withdraws stuck ERC20 tokens from the contract
	/// @dev Can only be called by contract owner.
	/// @dev For treasury-managed tokens (coin_config.token_address and CREDIT_TOKEN_ADDRESS), use treasury.withdraw()
	/// @param token Address of the ERC20 token to withdraw
	/// @param amount Amount of tokens to withdraw
	function emergencyWithdrawErc20(address token, uint256 amount) external onlyOwner {
		IERC20(token).safeTransfer(msg.sender, amount);
	}

	/// @notice Approves the treasury to spend this contract's tokens (max approval)
	/// @dev Anyone can call — only approves from this contract, not from the caller
	function approveTreasuryForTokens() external {
		IERC20(coin_config.token_address).approve(hot_treasury_address, type(uint256).max);
		IERC20(credit_token_address).approve(hot_treasury_address, type(uint256).max);
	}

	uint256[45] private __gap;
}
