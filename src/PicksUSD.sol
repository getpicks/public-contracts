// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title PicksUSD — Free-to-Play token minted via signed backend authorization
/// @notice Users request tokens off-chain; the backend signs a mint authorization.
///         Each signature is keyed by a backend-chosen idempotency key and time-bounded (deadline).
///         The same signed payload can be submitted multiple times safely — it only ever mints once.
/// @dev Transfer restrictions:
///      - Regular users cannot transfer tokens to each other.
///      - Only whitelisted addresses (e.g. F2P HotContest treasury) can initiate transfers.
///      - Whitelisted addresses have implicit permanent max allowance — approve() is disabled.
///      This ensures everyone starts with the same airdropped balance and
///      the only way tokens move is through the game (deposit into treasury / winnings out).
contract PicksUSD is ERC20, Ownable {
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	/// @notice Address whose signature authorizes mints
	address public automated_authority_address;

	/// @notice Idempotency keys that have already been used
	mapping(bytes32 => bool) public used_keys;

	/// @notice Addresses allowed to initiate transfers (e.g. F2P HotContest treasury)
	mapping(address => bool) public whitelisted_addresses;

	bytes32 internal constant MINT_TYPEHASH = keccak256("mint");

	event AutomatedAuthorityUpdated(address indexed old_address, address indexed new_address);
	event Minted(address indexed to, uint256 amount, bytes32 indexed idempotency_key);
	event AddressWhitelisted(address indexed addr);
	event AddressRemovedFromWhitelist(address indexed addr);

	error InvalidSignature();
	error SignatureExpired();
	error InvalidInput();
	error IdempotencyKeyAlreadyUsed();
	error Unauthorized();
	error NotSupported();

	constructor(
		address _automated_authority_address,
		address _owner
	) ERC20("USD.P", "USD.P") Ownable(_owner) {
		if (_automated_authority_address == address(0)) revert InvalidInput();
		automated_authority_address = _automated_authority_address;
	}

	/// @notice Mints tokens to an address using a signature from the automated authority
	/// @param to Address to mint tokens to
	/// @param amount Amount of tokens to mint
	/// @param deadline Timestamp after which the signature expires
	/// @param idempotency_key Unique key chosen by the backend — reverts if already used
	/// @param signature Signature from automated_authority_address
	function mint(
		address to,
		uint256 amount,
		uint256 deadline,
		bytes32 idempotency_key,
		bytes calldata signature
	) external {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		if (idempotency_key == bytes32(0)) revert InvalidInput();
		if (block.timestamp > deadline) revert SignatureExpired();
		if (used_keys[idempotency_key]) revert IdempotencyKeyAlreadyUsed();

		bytes32 message_hash = keccak256(abi.encode(MINT_TYPEHASH, block.chainid, address(this), to, amount, deadline, idempotency_key));
		address signer = message_hash.toEthSignedMessageHash().recover(signature);
		if (signer != automated_authority_address) revert InvalidSignature();

		used_keys[idempotency_key] = true;
		_mint(to, amount);

		emit Minted(to, amount, idempotency_key);
	}

	/// @notice Mints tokens to multiple addresses in a single call
	/// @param tos Addresses to mint tokens to
	/// @param amounts Amounts of tokens to mint, one per recipient
	/// @param deadline Timestamp after which all signatures in this batch expire
	/// @param idempotency_keys Unique keys chosen by the backend, one per mint
	/// @param signatures Signatures from automated_authority_address, one per mint
	function batchMint(
		address[] calldata tos,
		uint256[] calldata amounts,
		uint256 deadline,
		bytes32[] calldata idempotency_keys,
		bytes[] calldata signatures
	) external {
		uint256 len = tos.length;
		if (len != amounts.length || len != idempotency_keys.length || len != signatures.length) revert InvalidInput();
		for (uint256 i = 0; i < len; ++i) {
			if (tos[i] == address(0)) revert InvalidInput();
			if (amounts[i] == 0) revert InvalidInput();
			if (idempotency_keys[i] == bytes32(0)) revert InvalidInput();
			if (block.timestamp > deadline) revert SignatureExpired();
			if (used_keys[idempotency_keys[i]]) revert IdempotencyKeyAlreadyUsed();

			bytes32 message_hash = keccak256(abi.encode(MINT_TYPEHASH, block.chainid, address(this), tos[i], amounts[i], deadline, idempotency_keys[i]));
			address signer = message_hash.toEthSignedMessageHash().recover(signatures[i]);
			if (signer != automated_authority_address) revert InvalidSignature();

			used_keys[idempotency_keys[i]] = true;
			_mint(tos[i], amounts[i]);

			emit Minted(tos[i], amounts[i], idempotency_keys[i]);
		}
	}

	/// @notice Returns balances for multiple addresses in a single call
	/// @param accounts Addresses to query
	/// @return balances Array of balances in the same order as accounts
	function balanceOfBatch(address[] calldata accounts) external view returns (uint256[] memory balances) {
		balances = new uint256[](accounts.length);
		for (uint256 i = 0; i < accounts.length; ++i) {
			balances[i] = balanceOf(accounts[i]);
		}
	}

	/// @notice Updates the automated authority address
	/// @param new_address New automated authority address
	function setAutomatedAuthority(address new_address) external onlyOwner {
		if (new_address == address(0)) revert InvalidInput();
		emit AutomatedAuthorityUpdated(automated_authority_address, new_address);
		automated_authority_address = new_address;
	}

	/// @notice Adds an address to the whitelist, allowing it to transfer tokens
	/// @param addr Address to whitelist (e.g. F2P HotContest treasury)
	function addToWhitelist(address addr) external onlyOwner {
		if (addr == address(0)) revert InvalidInput();
		whitelisted_addresses[addr] = true;
		emit AddressWhitelisted(addr);
	}

	/// @notice Removes an address from the whitelist
	/// @param addr Address to remove
	function removeFromWhitelist(address addr) external onlyOwner {
		whitelisted_addresses[addr] = false;
		emit AddressRemovedFromWhitelist(addr);
	}

	// ─── Transfer restriction overrides ──────────────────────────────────────

	/// @notice Disabled — whitelisted addresses have implicit permanent approval
	function approve(address, uint256) public pure override returns (bool) {
		revert NotSupported();
	}

	/// @notice Whitelisted addresses always have max allowance; others have zero
	function allowance(address owner, address spender) public view override returns (uint256) {
		if (whitelisted_addresses[spender]) {
			return type(uint256).max;
		}
		return super.allowance(owner, spender);
	}

	/// @notice Only whitelisted addresses can send tokens
	function transfer(address to, uint256 value) public override returns (bool) {
		if (!whitelisted_addresses[msg.sender]) revert Unauthorized();
		return super.transfer(to, value);
	}

	/// @notice Only whitelisted addresses can pull tokens via transferFrom
	function transferFrom(address from, address to, uint256 value) public override returns (bool) {
		if (!whitelisted_addresses[msg.sender]) revert Unauthorized();
		_transfer(from, to, value);
		return true;
	}
}
