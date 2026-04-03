// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IEventMarketRegistry} from "./IEventMarketRegistry.sol";

/// @title EventMarketRegistry - Shared Event Market Registry
/// @notice Stores event markets shared across multiple betting contracts (ComboMachine, FlexComboMachine, etc.)
/// @dev Settle/void/update happen once here instead of per-contract. Betting contracts call ensureExists during bet placement.
/// @dev Automated Authority Signature System:
///      - settleEventMarket: Requires automated_authority signature with event_market_id, winning_outcome_id, and signature_deadline
///      - voidEventMarket: Requires automated_authority signature with event_market_id and signature_deadline
///      - updateEventMarket: Requires automated_authority signature with event_market_id, new_min_settlement_ts, nonce, and signature_deadline
///      - Message format for settle: keccak256(abi.encode(SETTLE_EVENT_TYPEHASH, chainid, contract_address, event_market_id, winning_outcome_id, signature_deadline))
///      - Message format for void: keccak256(abi.encode(VOID_EVENT_TYPEHASH, chainid, contract_address, event_market_id, signature_deadline))
///      - Message format for update: keccak256(abi.encode(UPDATE_EVENT_MARKET_TYPEHASH, chainid, contract_address, event_market_id, new_min_settlement_ts, nonce, signature_deadline))
///      - Nonce increments with each updateEventMarket call to prevent replay attacks
///      - signature_deadline prevents replay attacks with stale signatures
contract EventMarketRegistry is IEventMarketRegistry, Initializable, Pausable {
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	bytes32 internal constant SETTLE_EVENT_TYPEHASH = keccak256("settleEventMarket");
	bytes32 internal constant VOID_EVENT_TYPEHASH = keccak256("voidEventMarket");
	bytes32 internal constant UPDATE_EVENT_MARKET_TYPEHASH = keccak256("updateEventMarket");

	bytes12 internal constant VOIDED_EVENT_OUTCOME_ID = bytes12(0);

	/// @notice Mapping from event market ID to event market data
	mapping(bytes12 => EventMarket) public event_markets;

	/// @notice Mapping of addresses authorized to create event markets (betting contracts)
	mapping(address => bool) public authorized_writers;

	/// @notice Address authorized to settle/void/update event markets
	address public automated_authority_address;

	/// @notice Nonce for automated_authority to prevent replay attacks on update operations
	uint256 public automated_authority_nonce;

	address public owner;

	uint256[44] private __gap;

	event EventMarketCreated(bytes12 indexed event_market_id, uint40 min_settlement_ts);

	event EventMarketSettled(bytes12 indexed event_market_id, bytes12 indexed winning_outcome_id);

	event EventMarketUpdated(bytes12 indexed event_market_id, uint40 new_min_settlement_ts);

	event AutomatedAuthorityNonceIncremented(uint256 old_nonce, uint256 new_nonce);

	event AuthorizedWriterAdded(address indexed writer);

	event AuthorizedWriterRemoved(address indexed writer);

	event ConfigurationUpdated(address automated_authority_address);

	event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

	error InvalidSignature();
	error InvalidInput();
	error Unauthorized();
	error EventMarketAlreadySettled();
	error EventMarketDoesNotExist();
	error TooEarlyToSettle();
	error BettingWindowClosed();
	error SignatureExpired();
	error OwnableUnauthorizedAccount(address account);
	error OwnableInvalidOwner(address owner);

	modifier onlyOwner() {
		_checkOwner();
		_;
	}

	modifier onlyAuthorizedWriter() {
		if (!authorized_writers[msg.sender]) revert Unauthorized();
		_;
	}

	constructor() {
		_disableInitializers();
	}

	/// @notice Initializes the registry contract
	/// @param _automated_authority_address Address authorized to settle/void/update event markets
	/// @param initial_owner Address that will own the contract
	function initialize(
		address _automated_authority_address,
		address initial_owner
	) external initializer {
		if (initial_owner == address(0)) revert InvalidInput();
		if (_automated_authority_address == address(0)) revert InvalidInput();

		automated_authority_address = _automated_authority_address;
		_transferOwnership(initial_owner);
	}

	/// @notice Ensures an event market exists, creating it if necessary
	/// @dev Called by authorized betting contracts during bet placement
	/// @dev Idempotent: creates if not exists, validates if exists (not settled, betting window open)
	/// @param event_market_id The event market ID
	/// @param min_settlement_ts Minimum settlement timestamp (only used for creation)
	function ensureExists(
		bytes12 event_market_id,
		uint40 min_settlement_ts
	) external onlyAuthorizedWriter whenNotPaused {
		if (event_market_id == bytes12(0)) revert InvalidInput();

		EventMarket storage market = event_markets[event_market_id];
		if (!market.is_exists) {
			if (min_settlement_ts <= block.timestamp) revert InvalidInput();
			event_markets[event_market_id] = EventMarket({
				is_exists: true,
				is_settled: false,
				min_settlement_ts: min_settlement_ts,
				winning_outcome_id: bytes12(0)
			});
			emit EventMarketCreated(event_market_id, min_settlement_ts);
		} else {
			if (market.is_settled) revert EventMarketAlreadySettled();
			if (block.timestamp >= market.min_settlement_ts) revert BettingWindowClosed();
		}
	}

	/// @notice Returns full event market data
	/// @param event_market_id The event market ID
	/// @return The event market data
	function getEventMarket(bytes12 event_market_id) external view returns (EventMarket memory) {
		return event_markets[event_market_id];
	}

	/// @notice Settles an event market with a winning outcome
	/// @dev Can be called by anyone with a valid automated_authority signature
	/// @dev Does not need a nonce because market can only be settled once
	/// @param event_market_id ID of the event market to settle
	/// @param winning_outcome_id ID of the winning outcome
	/// @param signature_deadline Timestamp after which the signature expires
	/// @param automated_authority_signature Signature from automated_authority_address
	function settleEventMarket(
		bytes12 event_market_id,
		bytes12 winning_outcome_id,
		uint256 signature_deadline,
		bytes calldata automated_authority_signature
	) external whenNotPaused {
		if (!event_markets[event_market_id].is_exists) revert EventMarketDoesNotExist();
		if (event_markets[event_market_id].is_settled) revert EventMarketAlreadySettled();
		if (block.timestamp < event_markets[event_market_id].min_settlement_ts)
			revert TooEarlyToSettle();
		if (winning_outcome_id == bytes12(0)) revert InvalidInput();
		if (block.timestamp > signature_deadline) revert SignatureExpired();

		bytes32 message_hash = keccak256(
			abi.encode(
				SETTLE_EVENT_TYPEHASH,
				block.chainid,
				address(this),
				event_market_id,
				winning_outcome_id,
				signature_deadline
			)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();

		event_markets[event_market_id].is_settled = true;
		event_markets[event_market_id].winning_outcome_id = winning_outcome_id;

		emit EventMarketSettled(event_market_id, winning_outcome_id);
	}

	/// @notice Voids an event market (for canceled/postponed events)
	/// @dev Can be called by anyone with a valid automated_authority signature
	/// @dev Does not need a nonce because market can only be voided once
	/// @param event_market_id ID of the event market to void
	/// @param signature_deadline Timestamp after which the signature expires
	/// @param automated_authority_signature Signature from automated_authority_address
	function voidEventMarket(
		bytes12 event_market_id,
		uint256 signature_deadline,
		bytes calldata automated_authority_signature
	) external whenNotPaused {
		if (!event_markets[event_market_id].is_exists) revert EventMarketDoesNotExist();
		if (event_markets[event_market_id].is_settled) revert EventMarketAlreadySettled();
		if (block.timestamp > signature_deadline) revert SignatureExpired();

		bytes32 message_hash = keccak256(
			abi.encode(
				VOID_EVENT_TYPEHASH,
				block.chainid,
				address(this),
				event_market_id,
				signature_deadline
			)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();

		event_markets[event_market_id].is_settled = true;
		event_markets[event_market_id].winning_outcome_id = VOIDED_EVENT_OUTCOME_ID;

		emit EventMarketSettled(event_market_id, VOIDED_EVENT_OUTCOME_ID);
	}

	/// @notice Updates an event market's minimum settlement timestamp
	/// @dev Can be called by anyone with a valid automated_authority signature
	/// @param event_market_id ID of the event market to update
	/// @param new_min_settlement_ts New minimum settlement timestamp
	/// @param signature_deadline Timestamp after which the signature expires
	/// @param automated_authority_signature Signature from automated_authority_address
	function updateEventMarket(
		bytes12 event_market_id,
		uint40 new_min_settlement_ts,
		uint256 signature_deadline,
		bytes calldata automated_authority_signature
	) external whenNotPaused {
		if (!event_markets[event_market_id].is_exists) revert EventMarketDoesNotExist();
		if (event_markets[event_market_id].is_settled) revert EventMarketAlreadySettled();

		if (block.timestamp > signature_deadline) revert SignatureExpired();

		bytes32 message_hash = keccak256(
			abi.encode(
				UPDATE_EVENT_MARKET_TYPEHASH,
				block.chainid,
				address(this),
				event_market_id,
				new_min_settlement_ts,
				automated_authority_nonce,
				signature_deadline
			)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(automated_authority_signature);

		if (signer != automated_authority_address) revert InvalidSignature();

		uint256 old_nonce = automated_authority_nonce;
		automated_authority_nonce = automated_authority_nonce + 1;
		emit AutomatedAuthorityNonceIncremented(old_nonce, automated_authority_nonce);

		if (new_min_settlement_ts <= block.timestamp) revert InvalidInput();

		event_markets[event_market_id].min_settlement_ts = new_min_settlement_ts;

		emit EventMarketUpdated(event_market_id, new_min_settlement_ts);
	}

	/// @notice Adds an authorized writer (betting contract)
	/// @param writer Address to authorize
	function addAuthorizedWriter(address writer) external onlyOwner {
		if (writer == address(0)) revert InvalidInput();
		authorized_writers[writer] = true;
		emit AuthorizedWriterAdded(writer);
	}

	/// @notice Removes an authorized writer
	/// @param writer Address to deauthorize
	function removeAuthorizedWriter(address writer) external onlyOwner {
		authorized_writers[writer] = false;
		emit AuthorizedWriterRemoved(writer);
	}

	/// @notice Updates the registry configuration
	/// @param new_automated_authority_address New automated authority address (address(0) to skip)
	function updateConfiguration(
		address new_automated_authority_address
	) external onlyOwner {
		if (new_automated_authority_address != address(0)) {
			automated_authority_address = new_automated_authority_address;
		}

		emit ConfigurationUpdated(automated_authority_address);
	}

	/// @notice Pauses the contract
	function pause() external onlyOwner {
		_pause();
	}

	/// @notice Unpauses the contract
	function unpause() external onlyOwner {
		_unpause();
	}

	/// @notice Transfers ownership to a new address
	/// @param newOwner Address of the new owner
	function transferOwnership(address newOwner) external onlyOwner {
		if (newOwner == address(0)) {
			revert OwnableInvalidOwner(address(0));
		}
		_transferOwnership(newOwner);
	}

	/// @notice Returns the current owner
	function _checkOwner() internal view {
		if (owner != msg.sender) {
			revert OwnableUnauthorizedAccount(msg.sender);
		}
	}

	/// @notice Internal ownership transfer
	function _transferOwnership(address newOwner) internal {
		address oldOwner = owner;
		owner = newOwner;
		emit OwnershipTransferred(oldOwner, newOwner);
	}
}
