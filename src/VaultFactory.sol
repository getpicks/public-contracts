// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVaultFactory} from "./IVaultFactory.sol";
import {EntryVault} from "./EntryVault.sol";
import {PrizeTreasury} from "./PrizeTreasury.sol";

/// @title VaultFactory — deploys and catalogs Arena vault pairs
///
/// @notice createVaultPair() deploys a fresh (EntryVault, PrizeTreasury) pair — each owned by
///         this factory's owner — and appends it to an append-only registry. A lineup stores the
///         `vault_pair_id` it was placed under; the machine resolves the addresses here on
///         placement, refund and settlement. The owner then configures token policies + whitelists
///         the machine on the returned vaults.
///
/// @dev CRUD-without-delete:
///        - CREATE: createVaultPair() deploys + registers a new pair, returns its id + addresses.
///        - READ:   getVaultPair() / vaultPairsCount().
///        - UPDATE: setVaultPairActive() toggles the `is_active` gate ONLY.
///        - DELETE: intentionally absent.
///      A pair's addresses are IMMUTABLE once created. To rotate vaults you create a new pair and
///      deactivate the old one — you never repoint an existing id, so a lineup placed under id N
///      always settles/refunds against the exact vaults that hold its funds. `is_active` only
///      governs which pairs NEW lineups may select; it never affects settlement of existing lineups.
contract VaultFactory is Ownable, IVaultFactory {
	struct VaultPair {
		address entry_vault;
		address prize_treasury;
		bool is_active;
	}

	VaultPair[] private vault_pairs;

	event VaultPairCreated(
		uint256 indexed id,
		address indexed entry_vault,
		address indexed prize_treasury,
		address vault_owner
	);
	event VaultPairActiveChanged(uint256 indexed id, bool is_active);

	error VaultPairDoesNotExist();

	constructor(address _owner) Ownable(_owner) {}

	/// @notice Deploys a fresh EntryVault + PrizeTreasury (owned by this factory's owner) and
	///         registers them as a new pair. Active on creation. The two vaults are distinct
	///         contracts by construction, so entry money and prize money never commingle (spec §7).
	function createVaultPair()
		external
		onlyOwner
		returns (uint256 id, address entry_vault, address prize_treasury)
	{
		address vault_owner = owner();
		entry_vault = address(new EntryVault(vault_owner));
		prize_treasury = address(new PrizeTreasury(vault_owner));

		id = vault_pairs.length;
		vault_pairs.push(
			VaultPair({entry_vault: entry_vault, prize_treasury: prize_treasury, is_active: true})
		);
		emit VaultPairCreated(id, entry_vault, prize_treasury, vault_owner);
	}

	/// @notice Enables/disables a pair for NEW lineups. Does not affect existing lineups.
	function setVaultPairActive(uint256 id, bool is_active) external onlyOwner {
		if (id >= vault_pairs.length) revert VaultPairDoesNotExist();
		vault_pairs[id].is_active = is_active;
		emit VaultPairActiveChanged(id, is_active);
	}

	/// @inheritdoc IVaultFactory
	function getVaultPair(uint256 id)
		external
		view
		returns (address entry_vault, address prize_treasury, bool is_active)
	{
		if (id >= vault_pairs.length) revert VaultPairDoesNotExist();
		VaultPair storage pair = vault_pairs[id];
		return (pair.entry_vault, pair.prize_treasury, pair.is_active);
	}

	/// @inheritdoc IVaultFactory
	function vaultPairsCount() external view returns (uint256) {
		return vault_pairs.length;
	}
}
