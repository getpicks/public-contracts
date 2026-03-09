// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEventMarketRegistry {
	struct EventMarket {
		bool is_exists;
		bool is_settled;
		uint40 min_settlement_ts;
		bytes12 winning_outcome_id;
	}

	/// @notice Ensures an event market exists, creating it if necessary
	/// @dev Idempotent: creates if not exists, validates if exists (not settled, betting window open)
	/// @param event_market_id The event market ID
	/// @param min_settlement_ts Minimum settlement timestamp (only used for creation)
	function ensureExists(bytes12 event_market_id, uint40 min_settlement_ts) external;

	/// @notice Returns full event market data
	/// @param event_market_id The event market ID
	/// @return The event market data
	function getEventMarket(bytes12 event_market_id) external view returns (EventMarket memory);
}
