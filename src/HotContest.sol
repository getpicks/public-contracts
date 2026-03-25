// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditToken} from "./ICreditToken.sol";

/// @title HotContest - Treasury with PNL-based Withdrawal Limits
/// @notice Manages funds for betting contracts with per-user PNL caps,
///         global daily drain limits, and admin withdrawal limits
/// @dev Replaces HotTreasury with risk-management features to prevent catastrophic drain
/// @dev Uses a 14-day rolling window (daily buckets) for PNL tracking
/// @dev PNL is tracked in COIN_ADDRESS decimals. Credit deposits count as real money for PNL.
///      Drains are only possible in COIN_ADDRESS (real token). Credit token can only be burned.
contract HotContest is Ownable {
	using SafeERC20 for IERC20;

	uint256 internal constant WINDOW_DAYS = 14;
	uint256 internal constant DAY_DURATION = 1 days;
	uint256 internal constant BPS_DENOMINATOR = 10_000;

	/// @notice Address of the real token (e.g. USDC) used for deposits/drains (immutable)
	address public immutable COIN_ADDRESS;

	/// @notice Address of the credit token used for burning (immutable)
	address public immutable CREDIT_TOKEN_ADDRESS;

	/// @notice Decimals of the coin token, cached for credit→coin conversion
	uint8 public immutable COIN_DECIMALS;

	/// @notice Mapping of whitelisted contracts that can deposit/drain funds
	mapping(address => bool) public whitelisted_contracts;

	/// @notice Absolute per-user 14-day PNL cap in COIN_ADDRESS decimals
	/// @dev Separate slot to support any coin decimals without overflow
	uint256 public max_pnl_amount;

	/// @notice BPS-based rate-limit caps packed into a single storage slot (48 bits total)
	struct BpsCaps {
		uint16 max_pnl_bps;            // Per-user PNL cap as % of treasury balance
		uint16 max_daily_drain_bps;    // Global daily drain cap as % of treasury balance
		uint16 admin_daily_withdraw_bps; // Admin daily withdrawal cap as % of treasury balance
	}

	/// @notice Current BPS rate-limit configuration (single SLOAD)
	BpsCaps public bps_caps;

	struct DayBucket {
		uint256 amount;
		uint256 day_index;
	}

	/// @dev user => 14 daily outflow buckets (rolling 2-week window)
	mapping(address => DayBucket[14]) internal user_outflows;

	/// @dev user => 14 daily inflow buckets (rolling 2-week window)
	mapping(address => DayBucket[14]) internal user_inflows;

	/// @dev Global daily drain tracker
	DayBucket internal global_daily_drain;

	/// @dev Admin daily withdrawal tracker
	DayBucket internal admin_withdrawn_today;

	event ContractWhitelisted(address indexed contract_address);
	event ContractRemovedFromWhitelist(address indexed contract_address);
	event Deposited(address indexed contract_address, address indexed user, address indexed token, uint256 amount);
	event FundsDrained(address indexed contract_address, address indexed to, uint256 amount);
	event CreditBurned(address indexed contract_address, uint256 amount);
	event FundsWithdrawn(address indexed to, uint256 amount);
	event PnlCredited(address indexed user, uint256 amount);
	event BpsCapsUpdated(uint16 max_pnl_bps, uint16 max_daily_drain_bps, uint16 admin_daily_withdraw_bps);

	error Unauthorized();
	error InvalidInput();
	error InvalidToken();
	error InvalidBps();
	error TransferFailed();
	error PnlAmountExceeded();
	error PnlBpsExceeded();
	error DailyDrainExceeded();
	error AdminWithdrawExceeded();

	modifier onlyWhitelisted() {
		if (!whitelisted_contracts[msg.sender]) revert Unauthorized();
		_;
	}

	/// @param _coin_address Address of the real token (e.g. USDC)
	/// @param _credit_token_address Address of the credit token
	/// @param _owner Address that will own the contract
	constructor(address _coin_address, address _credit_token_address, address _owner) Ownable(_owner) {
		if (_coin_address == address(0)) revert InvalidInput();
		if (_credit_token_address == address(0)) revert InvalidInput();

		uint8 _coin_decimals = IERC20Metadata(_coin_address).decimals();
		if (_coin_decimals > 18) revert InvalidInput();
		if (IERC20Metadata(_credit_token_address).decimals() != 18) revert InvalidInput();

		COIN_ADDRESS = _coin_address;
		CREDIT_TOKEN_ADDRESS = _credit_token_address;
		COIN_DECIMALS = _coin_decimals;
	}

	// ─── Whitelisted Contract Functions ───

	/// @notice Deposits funds from a user into the treasury, tracking the inflow for PNL
	/// @dev Accepts both COIN_ADDRESS and CREDIT_TOKEN_ADDRESS.
	///      Credit deposits are converted to coin-equivalent for PNL tracking.
	/// @param user Address of the user depositing
	/// @param token Address of the token (must be COIN_ADDRESS or CREDIT_TOKEN_ADDRESS)
	/// @param amount Amount to deposit (in token's native decimals)
	function depositFor(address user, address token, uint256 amount) external onlyWhitelisted {
		if (user == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		if (token != COIN_ADDRESS && token != CREDIT_TOKEN_ADDRESS) revert InvalidToken();

		IERC20(token).safeTransferFrom(user, address(this), amount);

		// Convert to coin decimals for PNL tracking
		uint256 pnl_amount = token == CREDIT_TOKEN_ADDRESS
			? _creditToCoin(amount)
			: amount;

		uint256 today = block.timestamp / DAY_DURATION;
		_recordBucket(user_inflows[user], today, pnl_amount);

		emit Deposited(msg.sender, user, token, amount);
	}

	/// @notice Drains funds from treasury to a user
	/// @dev Accepts COIN_ADDRESS or CREDIT_TOKEN_ADDRESS. Credits are treated as real money —
	///      all PNL and daily drain caps apply. Credit amounts are converted to coin-equivalent for checks.
	/// @param to Address to send funds to
	/// @param token Token to drain (must be COIN_ADDRESS or CREDIT_TOKEN_ADDRESS)
	/// @param amount Amount to drain (coin decimals for COIN, 18 decimals for credit)
	function drain(address to, address token, uint256 amount) external onlyWhitelisted {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		if (token != COIN_ADDRESS && token != CREDIT_TOKEN_ADDRESS) revert InvalidToken();

		// Convert to coin-equivalent for PNL tracking and cap checks
		uint256 pnl_amount = token == CREDIT_TOKEN_ADDRESS ? _creditToCoin(amount) : amount;

		uint256 balance = IERC20(COIN_ADDRESS).balanceOf(address(this));
		uint256 today = block.timestamp / DAY_DURATION;

		// --- Per-user PNL check (14-day rolling window) ---
		uint256 window_out = _windowSum(user_outflows[to]) + pnl_amount;
		uint256 window_in = _windowSum(user_inflows[to]);
		uint256 pnl = window_out > window_in ? window_out - window_in : 0;

		uint256 abs_cap = max_pnl_amount;
		if (abs_cap > 0 && pnl > abs_cap) revert PnlAmountExceeded();

		// Single SLOAD for all BPS caps
		BpsCaps memory c = bps_caps;

		if (c.max_pnl_bps > 0) {
			uint256 bps_limit = balance * c.max_pnl_bps / BPS_DENOMINATOR;
			if (pnl > bps_limit) revert PnlBpsExceeded();
		}

		// --- Global daily drain check ---
		if (c.max_daily_drain_bps > 0) {
			DayBucket storage gd = global_daily_drain;
			uint256 today_drain = (gd.day_index == today ? gd.amount : 0) + pnl_amount;
			uint256 daily_limit = balance * c.max_daily_drain_bps / BPS_DENOMINATOR;
			if (today_drain > daily_limit) revert DailyDrainExceeded();
			gd.amount = today_drain;
			gd.day_index = today;
		}

		// --- Record outflow and transfer ---
		_recordBucket(user_outflows[to], today, pnl_amount);
		IERC20(token).safeTransfer(to, amount);

		emit FundsDrained(msg.sender, to, amount);
	}

	/// @notice Burns credit tokens from treasury
	/// @dev Called by whitelisted Machine contracts. No PNL tracking for burns.
	/// @param amount Amount of credit tokens to burn
	function burnCredit(uint256 amount) external onlyWhitelisted {
		if (amount == 0) revert InvalidInput();
		ICreditToken(CREDIT_TOKEN_ADDRESS).burn(amount);
		emit CreditBurned(msg.sender, amount);
	}

	// ─── Owner Functions ───

	/// @notice Withdraws real token funds from treasury with daily cap
	/// @param to Address to send funds to
	/// @param amount Amount to withdraw (in coin decimals)
	function withdraw(address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		uint256 cap_bps = bps_caps.admin_daily_withdraw_bps;
		if (cap_bps > 0) {
			uint256 balance = IERC20(COIN_ADDRESS).balanceOf(address(this));
			uint256 today = block.timestamp / DAY_DURATION;

			DayBucket storage aw = admin_withdrawn_today;
			uint256 today_withdrawn = (aw.day_index == today ? aw.amount : 0) + amount;
			uint256 daily_limit = balance * cap_bps / BPS_DENOMINATOR;
			if (today_withdrawn > daily_limit) revert AdminWithdrawExceeded();

			aw.amount = today_withdrawn;
			aw.day_index = today;
		}

		IERC20(COIN_ADDRESS).safeTransfer(to, amount);
		emit FundsWithdrawn(to, amount);
	}

	/// @notice Withdraws ETH from treasury (emergency function)
	function withdrawEth() external onlyOwner {
		uint256 balance = address(this).balance;
		if (balance == 0) revert InvalidInput();

		(bool success, ) = msg.sender.call{value: balance}("");
		if (!success) revert TransferFailed();
	}

	// ─── Admin Configuration ───

	function addToWhitelist(address contract_address) external onlyOwner {
		if (contract_address == address(0)) revert InvalidInput();
		whitelisted_contracts[contract_address] = true;
		emit ContractWhitelisted(contract_address);
	}

	function removeFromWhitelist(address contract_address) external onlyOwner {
		whitelisted_contracts[contract_address] = false;
		emit ContractRemovedFromWhitelist(contract_address);
	}

	/// @notice Credits a user's PNL inflow without moving any funds
	///
	/// @dev Purpose:
	///      PNL caps may block legitimate payouts when a user has an exceptional win streak.
	///      For example, a user with a 500 USDC PNL cap wins 3 bets in a row for a total
	///      of 600 USDC profit. The 4th payout would revert with PnlAmountExceeded.
	///      The admin can call this function to record a virtual inflow (e.g. 200 USDC) which
	///      reduces the user's net PNL from 600 to 400, unblocking the next drain.
	///
	/// @dev How it works:
	///      Records `amount` as an inflow in the user's rolling window buckets, identical to
	///      what depositFor() does — but without any token transfer. The funds are already in
	///      the treasury; this only adjusts the PNL accounting.
	///
	/// @dev Safety:
	///      - Does NOT bypass PNL checks. After crediting, the user's PNL is recalculated
	///        normally on the next drain(). If the credit isn't large enough, the drain still reverts.
	///      - Only the contract owner can call this function.
	///      - The credit follows the same 14-day rolling window as regular inflows — it naturally
	///        expires after 14 days, so it cannot permanently inflate a user's allowance.
	///      - Emits PnlCredited event for auditability.
	///
	/// @param user Address of the user to credit
	/// @param amount Amount to credit as inflow (in coin decimals)
	function adminCreditPnl(address user, uint256 amount) external onlyOwner {
		if (user == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		uint256 today = block.timestamp / DAY_DURATION;
		_recordBucket(user_inflows[user], today, amount);

		emit PnlCredited(user, amount);
	}

	/// @notice Updates the absolute PNL amount cap
	/// @param amount New max PNL amount (in COIN_ADDRESS decimals, 0 = unlimited)
	function setMaxPnlAmount(uint256 amount) external onlyOwner {
		max_pnl_amount = amount;
	}

	/// @notice Updates all BPS-based rate-limit caps in a single SSTORE
	/// @param _caps New BPS caps configuration
	function updateBpsCaps(BpsCaps calldata _caps) external onlyOwner {
		if (_caps.max_pnl_bps > BPS_DENOMINATOR) revert InvalidBps();
		if (_caps.max_daily_drain_bps > BPS_DENOMINATOR) revert InvalidBps();
		if (_caps.admin_daily_withdraw_bps > BPS_DENOMINATOR) revert InvalidBps();
		bps_caps = _caps;
		emit BpsCapsUpdated(_caps.max_pnl_bps, _caps.max_daily_drain_bps, _caps.admin_daily_withdraw_bps);
	}

	// ─── View Functions ───

	function getBalance() external view returns (uint256) {
		return IERC20(COIN_ADDRESS).balanceOf(address(this));
	}

	/// @notice Returns the current PNL for a user over the rolling 14-day window (in coin decimals)
	function getUserPnl(address user) external view returns (uint256) {
		uint256 window_out = _windowSum(user_outflows[user]);
		uint256 window_in = _windowSum(user_inflows[user]);
		return window_out > window_in ? window_out - window_in : 0;
	}

	/// @notice Returns today's total global drain (in coin decimals)
	function getGlobalDailyDrain() external view returns (uint256) {
		uint256 today = block.timestamp / DAY_DURATION;
		return global_daily_drain.day_index == today ? global_daily_drain.amount : 0;
	}

	/// @notice Returns today's admin withdrawal (in coin decimals)
	function getAdminWithdrawnToday() external view returns (uint256) {
		uint256 today = block.timestamp / DAY_DURATION;
		return admin_withdrawn_today.day_index == today ? admin_withdrawn_today.amount : 0;
	}

	// ─── Internal ───

	/// @dev Converts credit token amount (18 decimals) to coin amount (COIN_DECIMALS)
	function _creditToCoin(uint256 credit_amount) internal view returns (uint256) {
		if (COIN_DECIMALS == 18) return credit_amount;
		return credit_amount / (10 ** (18 - COIN_DECIMALS));
	}

	/// @dev Sums the last 14 days of a bucket array (rolling window)
	function _windowSum(DayBucket[14] storage buckets) internal view returns (uint256) {
		uint256 today = block.timestamp / DAY_DURATION;
		uint256 total = 0;
		for (uint256 i = 0; i < WINDOW_DAYS; ++i) {
			if (today < i) break;
			uint256 target_day = today - i;
			uint256 slot = target_day % WINDOW_DAYS;
			if (buckets[slot].day_index == target_day) {
				total += buckets[slot].amount;
			}
		}
		return total;
	}

	/// @dev Records an amount into today's bucket, resetting if stale
	function _recordBucket(DayBucket[14] storage buckets, uint256 today, uint256 amount) internal {
		uint256 slot = today % WINDOW_DAYS;
		if (buckets[slot].day_index == today) {
			buckets[slot].amount += amount;
		} else {
			buckets[slot].amount = amount;
			buckets[slot].day_index = today;
		}
	}

	/// @notice Allows contract to receive ETH directly
	receive() external payable {}
}
