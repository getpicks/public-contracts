// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BaseVault — generic multi-token custody + guardrails for the Picks Arena vault pair
///
/// @notice Dumb custody. The vault does NOT care what a token "means" (coin vs credit vs
///         anything else) — that is gameplay logic in the machine. It just holds whatever
///         tokens the owner configures and lets an owner-approved (whitelisted) machine move
///         them out, bounded by that token's own safety limits:
///
///           LAYER 0 — operator whitelist: only approved machines may pay out (fail-safe:
///                     empty whitelist means nobody can move funds).
///           LAYER 1 — per-token min balance floor: an automated payout that would push the
///                     token balance below its floor reverts (the real total-drain guard).
///           LAYER 2 — per-token max drain per tx: an automated payout larger than the token's
///                     cap reverts (a single-payout sanity bound).
///
///         Both limits are PER TOKEN (`token_policy`) and apply ONLY to the automated
///         (whitelisted-machine) `payout` path via `_sendOut`. Admin/owner methods
///         (withdraw / recover) are deliberately EXEMPT — the owner is the trusted recovery
///         path and must not be rate-limited. A token must be `supported` before it can be
///         deposited, funded or paid out; limits default to 0 (disabled).
abstract contract BaseVault is Ownable, Pausable {
	using SafeERC20 for IERC20;

	struct TokenPolicy {
		bool supported;
		uint256 min_balance; // LAYER 1 floor for this token (0 = disabled)
		uint256 max_drain_per_tx; // LAYER 2 cap for this token (0 = unlimited)
	}

	/// @notice Whitelisted operator machines allowed to deposit / pay out.
	mapping(address => bool) public whitelisted_contracts;

	/// @notice Per-token support flag + safety limits. The "hashmap" of what this vault holds.
	mapping(address => TokenPolicy) public token_policy;

	event ContractWhitelisted(address indexed contract_address);
	event ContractRemovedFromWhitelist(address indexed contract_address);
	event TokenPolicyUpdated(address indexed token, bool supported, uint256 min_balance, uint256 max_drain_per_tx);
	event Funded(address indexed from, address indexed token, uint256 amount);
	event Payout(address indexed contract_address, address indexed to, address indexed token, uint256 amount);
	event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);
	event TokenRecovered(address indexed token, address indexed to, uint256 amount);

	error Unauthorized();
	error InvalidInput();
	error TokenNotSupported();
	error TokenIsSupported();
	error TransferFailed();
	error DrainPerTxExceeded();
	error MinBalanceFloorBreached();

	modifier onlyWhitelisted() {
		if (!whitelisted_contracts[msg.sender]) revert Unauthorized();
		_;
	}

	constructor(address _owner) Ownable(_owner) {}

	// ─── Whitelisted machine outflow (guarded, generic) ───

	/// @notice Pay `amount` of `token` out to `to` on the automated path. Enforces the token's
	///         per-tx cap (LAYER 2) then its balance floor (LAYER 1). The calling machine bounds
	///         `amount` to a recorded entry/prize; the vault only ever moves supported tokens.
	function payout(address to, address token, uint256 amount) public virtual onlyWhitelisted whenNotPaused {
		_sendOut(to, token, amount);
		emit Payout(msg.sender, to, token, amount);
	}

	function _sendOut(address to, address token, uint256 amount) internal {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		TokenPolicy memory policy = token_policy[token];
		if (!policy.supported) revert TokenNotSupported();

		if (policy.max_drain_per_tx > 0 && amount > policy.max_drain_per_tx) revert DrainPerTxExceeded();

		if (policy.min_balance > 0) {
			uint256 balance = IERC20(token).balanceOf(address(this));
			if (balance < amount || balance - amount < policy.min_balance) revert MinBalanceFloorBreached();
		}

		IERC20(token).safeTransfer(to, amount);
	}

	// ─── Owner inflow ───

	/// @notice Fund the vault with a supported token (company capital). Owner-only inflow.
	function fund(address token, uint256 amount) external onlyOwner {
		if (amount == 0) revert InvalidInput();
		if (!token_policy[token].supported) revert TokenNotSupported();
		IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
		emit Funded(msg.sender, token, amount);
	}

	// ─── Owner outflow (EXEMPT from the floor + per-tx cap) ───

	/// @notice Sweep a token out (capital management / emergency recovery). Not rate-limited.
	function withdraw(address token, address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		IERC20(token).safeTransfer(to, amount);
		emit FundsWithdrawn(token, to, amount);
	}

	/// @notice Recover a NON-supported token accidentally sent here (a supported token is vault
	///         business and must leave only via payout / withdraw).
	function recoverToken(address token, address to) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (token_policy[token].supported) revert TokenIsSupported();

		uint256 balance = IERC20(token).balanceOf(address(this));
		if (balance == 0) revert InvalidInput();
		IERC20(token).safeTransfer(to, balance);
		emit TokenRecovered(token, to, balance);
	}

	function withdrawEth() external onlyOwner {
		uint256 balance = address(this).balance;
		if (balance == 0) revert InvalidInput();
		(bool success, ) = msg.sender.call{value: balance}("");
		if (!success) revert TransferFailed();
	}

	// ─── Admin configuration ───

	function setTokenPolicy(
		address token,
		bool supported,
		uint256 min_balance,
		uint256 max_drain_per_tx
	) external onlyOwner {
		if (token == address(0)) revert InvalidInput();
		token_policy[token] = TokenPolicy({
			supported: supported,
			min_balance: min_balance,
			max_drain_per_tx: max_drain_per_tx
		});
		emit TokenPolicyUpdated(token, supported, min_balance, max_drain_per_tx);
	}

	function addToWhitelist(address contract_address) external onlyOwner {
		if (contract_address == address(0)) revert InvalidInput();
		whitelisted_contracts[contract_address] = true;
		emit ContractWhitelisted(contract_address);
	}

	function removeFromWhitelist(address contract_address) external onlyOwner {
		whitelisted_contracts[contract_address] = false;
		emit ContractRemovedFromWhitelist(contract_address);
	}

	function pause() external onlyOwner {
		_pause();
	}

	function unpause() external onlyOwner {
		_unpause();
	}

	// ─── Views ───

	function getBalance(address token) external view returns (uint256) {
		return IERC20(token).balanceOf(address(this));
	}

	receive() external payable {}
}
