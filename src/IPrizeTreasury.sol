// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPrizeTreasury — the "money out" side of a Picks Arena vault pair.
/// @notice Company pre-funded pool that pays winnings only (leaderboard win / minimum
///         guarantee). It NEVER receives entries (no depositFor), so its balance is provably
///         company capital, never pooled from entries (spec §7). Prizes are paid in the coin.
interface IPrizeTreasury {
	/// @notice Pay `amount` of `token` (the coin) out to a winner `to`. Bounded by the token's
	///         per-tx cap + balance floor.
	function payout(address to, address token, uint256 amount) external;
}
