// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";
import {IPrizeTreasury} from "./IPrizeTreasury.sol";

/// @title PrizeTreasury — the "money out" side of a Picks Arena vault pair
///
/// @notice A BaseVault that deliberately has NO machine-inflow path (no depositFor): the
///         only way funds enter is the owner's BaseVault.fund(), so the balance is provably
///         company capital, never pooled from entries (spec §7). Prizes leave via the generic
///         BaseVault.payout (whitelisted machine, per-token floor + cap). There is no on-chain
///         path that moves funds from an EntryVault into this contract; it is replenished
///         off-chain from general company funds. Keep the drainable float minimal.
contract PrizeTreasury is BaseVault, IPrizeTreasury {
	constructor(address _owner) BaseVault(_owner) {}

	/// @dev Resolve the diamond between BaseVault (impl) and IPrizeTreasury (declaration).
	function payout(address to, address token, uint256 amount) public override(BaseVault, IPrizeTreasury) {
		super.payout(to, token, amount);
	}
}
