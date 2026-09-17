// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IEntryVault — the "money in" side of a Picks Arena vault pair.
/// @notice Collects entry fees (depositFor) and pays them back out (payout — refunds and
///         consumed-credit recycling). It NEVER pays winnings; prizes come exclusively from
///         the PrizeTreasury, so entries and prize funds never commingle on-chain (spec §7).
interface IEntryVault {
	/// @notice Pull an entry fee from `user` into the vault.
	function depositFor(address user, address token, uint256 amount) external;

	/// @notice Pay `amount` of `token` out to `to` (refund / recycle). Bounded by the token's
	///         per-tx cap + balance floor; the caller (machine) bounds `amount` to a recorded entry.
	function payout(address to, address token, uint256 amount) external;
}
