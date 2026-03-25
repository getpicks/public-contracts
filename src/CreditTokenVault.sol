// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title CreditTokenVault
/// @notice Vault for distributing credit tokens to users in batches
/// @dev Distributions can be executed by anyone with a valid distributor signature
/// @dev Signature System:
///      - distribute/batchDistribute: Requires distributor signature with parameters
///      - Nonce is read from storage and used in signature verification
///      - Message format for single: keccak256(abi.encode(DISTRIBUTE_TYPEHASH, chainid, contract_address, recipient, amount, idempotency_key, nonce))
///      - Message format for batch: keccak256(abi.encode(BATCH_DISTRIBUTE_TYPEHASH, chainid, contract_address, recipients, amounts, idempotency_keys, nonce))
///      - Distributor nonce increments with each distribution to prevent replay attacks
contract CreditTokenVault is Ownable {
	using SafeERC20 for IERC20;
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	bytes32 internal constant DISTRIBUTE_TYPEHASH = keccak256("distribute");
	bytes32 internal constant BATCH_DISTRIBUTE_TYPEHASH = keccak256("batchDistribute");

	IERC20 public immutable CREDIT_TOKEN;

	/// @notice Address authorized to sign distribution approvals
	address public distributor_address;

	/// @notice Nonce for distributor to prevent replay attacks on distribution operations
	uint256 public distributor_nonce;

	/// @notice Mapping to track used idempotency keys
	mapping(bytes32 => bool) public used_idempotency_keys;

	event CreditDeposited(address indexed depositor, uint256 amount);
	event CreditDistributed(address indexed recipient, uint256 amount, bytes32 idempotency_key);
	event CreditWithdrawn(address indexed recipient, uint256 amount);
	event BatchDistributionCompleted(uint256 total_recipients, uint256 total_amount);
	event DistributorAddressUpdated(address indexed old_distributor, address indexed new_distributor);
	event DistributorNonceIncremented(uint256 old_nonce, uint256 new_nonce);

	error InvalidAddress();
	error InvalidAmount();
	error ArrayLengthMismatch();
	error DuplicateIdempotencyKey();
	error InvalidDecimals();
	error InvalidSignature();
	error InvalidInput();

	constructor(address _CREDIT_TOKEN, address _distributor, address _owner) Ownable(_owner) {
		if (_CREDIT_TOKEN == address(0)) revert InvalidAddress();
		if (_distributor == address(0)) revert InvalidAddress();
		if (_owner == address(0)) revert InvalidAddress();

		uint8 decimals = IERC20Metadata(_CREDIT_TOKEN).decimals();
		if (decimals != 18) revert InvalidDecimals();

		CREDIT_TOKEN = IERC20(_CREDIT_TOKEN);
		distributor_address = _distributor;
	}

	/// @notice Deposits credit tokens into the vault
	/// @param amount Amount of credit tokens to deposit
	/// @dev This contract must be whitelisted in the CreditToken contract before calling this function
	function deposit(uint256 amount) external {
		if (amount == 0) revert InvalidAmount();
		CREDIT_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
		emit CreditDeposited(msg.sender, amount);
	}

	/// @notice Distributes credit tokens to a single recipient
	/// @dev Can be called by anyone with a valid distributor signature
	/// @param recipient Address to send tokens to
	/// @param amount Amount of tokens to send
	/// @param idempotency_key Unique key to prevent duplicate distributions
	/// @param distributor_signature Signature from distributor_address
	function distribute(
		address recipient,
		uint256 amount,
		bytes32 idempotency_key,
		bytes calldata distributor_signature
	) external {
		_verifyAndIncrementNonce(recipient, amount, idempotency_key, distributor_signature);
		_distributeInternal(recipient, amount, idempotency_key);
	}

	/// @notice Distributes credit tokens to multiple recipients in a single transaction
	/// @dev Can be called by anyone with a valid distributor signature. Each transfer has its own idempotency key.
	/// @param recipients Array of addresses to send tokens to
	/// @param amounts Array of amounts to send to each recipient
	/// @param idempotency_keys Array of unique keys to prevent duplicate distributions (one per transfer)
	/// @param distributor_signature Signature from distributor_address
	function batchDistribute(
		address[] calldata recipients,
		uint256[] calldata amounts,
		bytes32[] calldata idempotency_keys,
		bytes calldata distributor_signature
	) external {
		uint256 length = recipients.length;
		if (length == 0) revert InvalidAmount();
		if (length != amounts.length) revert ArrayLengthMismatch();
		if (length != idempotency_keys.length) revert ArrayLengthMismatch();

		_verifyBatchAndIncrementNonce(recipients, amounts, idempotency_keys, distributor_signature);

		// Perform distributions
		uint256 total_amount = 0;
		for (uint256 i = 0; i < length; ++i) {
			_distributeInternal(recipients[i], amounts[i], idempotency_keys[i]);
			total_amount += amounts[i];
		}

		emit BatchDistributionCompleted(length, total_amount);
	}

	/// @notice Internal function to verify signature and increment nonce for single distribution
	/// @param recipient Address to send tokens to
	/// @param amount Amount of tokens to send
	/// @param idempotency_key Unique key to prevent duplicate distributions
	/// @param distributor_signature Signature from distributor_address
	function _verifyAndIncrementNonce(
		address recipient,
		uint256 amount,
		bytes32 idempotency_key,
		bytes calldata distributor_signature
	) internal {
		uint256 nonce = distributor_nonce;

		bytes32 message_hash = keccak256(
			abi.encode(DISTRIBUTE_TYPEHASH, block.chainid, address(this), recipient, amount, idempotency_key, nonce)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(distributor_signature);

		if (signer != distributor_address) revert InvalidSignature();

		distributor_nonce = nonce + 1;
		emit DistributorNonceIncremented(nonce, nonce + 1);
	}

	/// @notice Internal function to verify signature and increment nonce for batch distribution
	/// @param recipients Array of addresses to send tokens to
	/// @param amounts Array of amounts to send to each recipient
	/// @param idempotency_keys Array of unique keys to prevent duplicate distributions
	/// @param distributor_signature Signature from distributor_address
	function _verifyBatchAndIncrementNonce(
		address[] calldata recipients,
		uint256[] calldata amounts,
		bytes32[] calldata idempotency_keys,
		bytes calldata distributor_signature
	) internal {
		uint256 nonce = distributor_nonce;

		_verifyBatchSignature(recipients, amounts, idempotency_keys, nonce, distributor_signature);

		distributor_nonce = nonce + 1;
		emit DistributorNonceIncremented(nonce, nonce + 1);
	}

	/// @notice Internal function to verify batch signature
	/// @param recipients Array of addresses to send tokens to
	/// @param amounts Array of amounts to send to each recipient
	/// @param idempotency_keys Array of unique keys to prevent duplicate distributions
	/// @param nonce Distributor nonce for replay protection
	/// @param distributor_signature Signature from distributor_address
	function _verifyBatchSignature(
		address[] calldata recipients,
		uint256[] calldata amounts,
		bytes32[] calldata idempotency_keys,
		uint256 nonce,
		bytes calldata distributor_signature
	) internal view {
		bytes32 message_hash = keccak256(
			abi.encode(BATCH_DISTRIBUTE_TYPEHASH, block.chainid, address(this), recipients, amounts, idempotency_keys, nonce)
		);
		bytes32 eth_signed_message_hash = message_hash.toEthSignedMessageHash();
		address signer = eth_signed_message_hash.recover(distributor_signature);

		if (signer != distributor_address) revert InvalidSignature();
	}

	/// @notice Internal function to perform a single distribution
	/// @dev Validates recipient, amount, idempotency key, then transfers tokens and emits event
	/// @param recipient Address to send tokens to
	/// @param amount Amount of tokens to send
	/// @param idempotency_key Unique key to prevent duplicate distributions
	function _distributeInternal(
		address recipient,
		uint256 amount,
		bytes32 idempotency_key
	) internal {
		if (recipient == address(0)) revert InvalidAddress();
		if (amount == 0) revert InvalidAmount();
		if (used_idempotency_keys[idempotency_key]) revert DuplicateIdempotencyKey();

		used_idempotency_keys[idempotency_key] = true;
		CREDIT_TOKEN.safeTransfer(recipient, amount);
		emit CreditDistributed(recipient, amount, idempotency_key);
	}

	/// @notice Updates the distributor address
	/// @dev Can only be called by owner
	/// @param new_distributor New distributor address
	function updateDistributor(address new_distributor) external onlyOwner {
		if (new_distributor == address(0)) revert InvalidAddress();
		address old_distributor = distributor_address;
		distributor_address = new_distributor;
		emit DistributorAddressUpdated(old_distributor, new_distributor);
	}

	/// @notice Withdraws credit tokens from the vault
	/// @dev Can only be called by owner
	/// @param recipient Address to send tokens to
	/// @param amount Amount of tokens to withdraw
	function withdraw(address recipient, uint256 amount) external onlyOwner {
		if (recipient == address(0)) revert InvalidAddress();
		if (amount == 0) revert InvalidAmount();
		CREDIT_TOKEN.safeTransfer(recipient, amount);
		emit CreditWithdrawn(recipient, amount);
	}

	/// @notice Returns the balance of credit tokens in the vault
	function balance() external view returns (uint256) {
		return CREDIT_TOKEN.balanceOf(address(this));
	}

	/// @notice Checks if an idempotency key has been used
	/// @param idempotency_key The key to check
	/// @return True if the key has been used, false otherwise
	function isIdempotencyKeyUsed(bytes32 idempotency_key) external view returns (bool) {
		return used_idempotency_keys[idempotency_key];
	}

	/// @notice Checks if multiple idempotency keys have been used
	/// @param idempotency_keys Array of keys to check
	/// @return used Array of booleans indicating which keys have been used
	function areIdempotencyKeysUsed(
		bytes32[] calldata idempotency_keys
	) external view returns (bool[] memory used) {
		uint256 length = idempotency_keys.length;
		used = new bool[](length);

		for (uint256 i = 0; i < length; ++i) {
			used[i] = used_idempotency_keys[idempotency_keys[i]];
		}

		return used;
	}
}
