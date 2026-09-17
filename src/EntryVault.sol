// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseVault} from "./BaseVault.sol";
import {IEntryVault} from "./IEntryVault.sol";

/// @title EntryVault — the "money in" side of a Picks Arena vault pair
///
/// @notice A BaseVault that ALSO lets a whitelisted machine pull entries in (depositFor).
///         Entries are collected here and returned here (refunds) or moved on (consumed
///         coupon credit recycled to the credit vault) via the generic BaseVault.payout.
///         The token semantics (which token is coin, which is credit, prize-in-coin, etc.)
///         live entirely in the machine — this vault is dumb custody.
contract EntryVault is BaseVault, IEntryVault {
	using SafeERC20 for IERC20;

	event Deposited(address indexed contract_address, address indexed user, address indexed token, uint256 amount);

	constructor(address _owner) BaseVault(_owner) {}

	/// @notice Pull an entry fee from `user` into the vault. Inflow — not rate-limited.
	function depositFor(address user, address token, uint256 amount) external onlyWhitelisted {
		if (user == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		if (!token_policy[token].supported) revert TokenNotSupported();

		IERC20(token).safeTransferFrom(user, address(this), amount);
		emit Deposited(msg.sender, user, token, amount);
	}

	/// @dev Resolve the diamond between BaseVault (impl) and IEntryVault (declaration).
	function payout(address to, address token, uint256 amount) public override(BaseVault, IEntryVault) {
		super.payout(to, token, amount);
	}
}
