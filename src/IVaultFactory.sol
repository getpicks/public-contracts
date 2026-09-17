// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVaultFactory — deploys + catalogs (EntryVault, PrizeTreasury) pairs.
/// @notice Each Arena lineup records the `vault_pair_id` that handled it, so its entry, refund
///         and prize always resolve to the correct vault pair even after new pairs are created.
///         Pairs are never deleted and their addresses are immutable once created — only the
///         `is_active` flag can change (it gates which pair NEW lineups may use), so historical
///         lineups always settle/refund against the exact vaults that held their funds.
interface IVaultFactory {
	/// @notice Resolve a vault pair by id.
	function getVaultPair(uint256 id)
		external
		view
		returns (address entry_vault, address prize_treasury, bool is_active);

	/// @notice Number of registered vault pairs (ids are 0..count-1).
	function vaultPairsCount() external view returns (uint256);
}
