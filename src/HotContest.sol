// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditToken} from "./ICreditToken.sol";

/// @title HotContest — Treasury with layered risk controls
///
/// @notice Holds USDC and credit tokens on behalf of Machine betting contracts.
///         Machines call depositFor() when a user places a bet and drain() when paying out.
///         The owner (a multisig) funds and manages the treasury.
///
/// @dev ─── SECURITY MODEL ────────────────────────────────────────────────────────────────
///
///   The primary attack surface is the AA (account abstraction) hot wallet that drives the
///   Machine contracts. If that key is compromised, an attacker can call drain() repeatedly
///   via a whitelisted Machine. The following independent layers limit the blast radius:
///
///   LAYER 0 — Whitelisting
///     Only addresses explicitly approved by the owner (multisig) can call depositFor(),
///     drain(), or burnCredit(). The owner key is separate from the AA hot wallet, so
///     compromising the AA key alone does not grant whitelist control.
///     Remediation: owner calls removeFromWhitelist() to immediately cut off a compromised
///     Machine without touching the treasury funds.
///
///   LAYER 1 — Internal coin_balance tracking  (anti-donation-attack)
///     coin_balance is incremented only by deposit() and depositFor(COIN), and decremented
///     only by drain(COIN) and withdraw(). It is never set from balanceOf().
///     Without this, an attacker could send USDC directly to the contract (no function call),
///     inflate the apparent treasury size, and loosen all BPS-based limits proportionally.
///     With internal tracking, donated tokens do not affect any cap calculation.
///
///   LAYER 2 — Credit deposit caps  (anti-credit-hack PNL inflation)
///     The credit token is a separate contract with its own key. If that key is compromised,
///     an attacker could mint unlimited credits and deposit them via depositFor() to inflate
///     the global inflow window, reducing apparent PNL, and then drain USDC up to the PNL cap.
///     Two independent sub-guards prevent this:
///       2a. Absolute cap (max_credit_balance): the total credit tokens held by this contract
///           can never exceed a fixed ceiling (e.g. 100k credits). Even if the credit contract
///           is fully compromised, the maximum PNL reduction achievable is bounded by this cap.
///       2b. Ratio cap (max_credit_coin_ratio_bps): credits held (USDC-equivalent) cannot
///           exceed X% of coin_balance (e.g. 50%). This scales with treasury size so a whale's
///           legitimate credit use is not arbitrarily blocked, while still bounding the exposure.
///     Both caps are checked before the transfer and revert immediately if exceeded.
///     Either cap alone is sufficient; both together provide defense-in-depth.
///
///   LAYER 4 — Global 14-day rolling PNL cap  (cumulative damage limit)
///     max_global_pnl_bps limits the net outflow (total drains minus total deposits, in
///     USDC-equivalent) over a rolling 14-day window as a percentage of the opening balance
///     snapshot. While the daily drain cap limits the speed of an attack, this cap limits the
///     total damage across a sustained multi-day campaign.
///     For legitimate high-volume users the cap is whale-friendly: large deposits reduce net
///     PNL and naturally make room for large payouts within the same window.
///     Deposits from credit tokens are converted to USDC-equivalent and counted as inflows,
///     so credit bets are fairly credited against the PNL accumulation.
///
///   LAYER 5 — Admin daily withdrawal cap  (owner key compromise mitigation)
///     admin_daily_withdraw_bps limits how much the owner can withdraw per day. This bounds
///     the damage if the owner multisig itself is compromised, and provides a tripwire for
///     detecting unauthorised withdrawals before the treasury is fully drained.
///     Uses the same daily balance snapshot as Layer 4 for consistency.
///
/// @dev ─── DESIGN NOTES ──────────────────────────────────────────────────────────────────
///
///   All BPS caps use a single daily balance snapshot (daily_balance_snapshot) taken on the
///   first drain or withdraw of each day. This ensures the PNL and admin withdrawal limits are
///   order-independent: the first payout does not lower the balance and tighten subsequent limits.
///
///   PNL amounts are always expressed in COIN_ADDRESS (USDC) decimals. Credit token amounts
///   are converted via _creditToCoin() before any tracking or cap comparison.
///
///   Setting any cap to 0 disables it (unlimited). All caps default to 0 at deployment.
///   The owner should set appropriate caps before funding the treasury.
///
/// ────────────────────────────────────────────────────────────────────────────────────────
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
	/// @dev See LAYER 0 in the security model above
	mapping(address => bool) public whitelisted_contracts;

	/// @notice Internally tracked coin balance
	/// @dev Incremented by deposit() and depositFor(COIN). Decremented by drain(COIN) and withdraw().
	///      Never derived from balanceOf(). See LAYER 1 in the security model above.
	uint256 public coin_balance;

	/// @notice Absolute ceiling on credit tokens held in this contract (credit token decimals, 0 = unlimited)
	/// @dev See LAYER 2a in the security model above
	uint256 public max_credit_balance;

	/// @notice Max credit coin-equivalent held as % of coin_balance, in BPS (0 = unlimited)
	/// @dev See LAYER 2b in the security model above. Example: 5000 = credits ≤ 50% of USDC balance.
	uint16 public max_credit_coin_ratio_bps;

	/// @notice BPS-based cumulative caps, packed into a single storage slot (32 bits)
	/// @dev See LAYERS 4, 5 in the security model above
	struct BpsCaps {
		uint16 max_global_pnl_bps;       // LAYER 4: global 14-day net PNL cap as % of opening balance
		uint16 admin_daily_withdraw_bps; // LAYER 5: owner daily withdrawal cap as % of opening balance
	}

	/// @notice Current BPS rate-limit configuration (single SLOAD)
	BpsCaps public bps_caps;

	struct DayBucket {
		uint256 amount;
		uint256 day_index;
	}

	/// @dev Global 14-day rolling outflow window (coin-equivalent amounts). See LAYER 4.
	DayBucket[14] internal global_outflows_window;

	/// @dev Global 14-day rolling inflow window (coin-equivalent amounts). See LAYER 4.
	DayBucket[14] internal global_inflows_window;

	/// @dev Cumulative admin withdrawal amount for the current calendar day. See LAYER 5.
	DayBucket internal admin_withdrawn_today;

	/// @dev coin_balance snapshot taken on the first drain/withdraw of each calendar day.
	///      All BPS cap calculations for that day use this fixed value, making limits
	///      order-independent regardless of how many payouts happen during the day.
	///      Stored as (coin_balance + 1): 0 = no snapshot yet today, 1 = balance was 0, etc.
	DayBucket internal daily_balance_snapshot;

	event ContractWhitelisted(address indexed contract_address);
	event ContractRemovedFromWhitelist(address indexed contract_address);
	event Deposited(address indexed contract_address, address indexed user, address indexed token, uint256 amount);
	event FundsDrained(address indexed contract_address, address indexed to, uint256 amount);
	event CreditBurned(address indexed contract_address, uint256 amount);
	event FundsWithdrawn(address indexed to, uint256 amount);
	event CreditWithdrawn(address indexed to, uint256 amount);
	event ExcessCoinWithdrawn(address indexed to, uint256 amount);
	event TokenRecovered(address indexed token, address indexed to, uint256 amount);
	event BpsCapsUpdated(uint16 max_global_pnl_bps, uint16 admin_daily_withdraw_bps);

	error Unauthorized();
	error InvalidInput();
	error InvalidToken();
	error InvalidBps();
	error TransferFailed();
	error GlobalPnlExceeded();
	error AdminWithdrawExceeded();
	error CreditCapExceeded();
	error CreditRatioExceeded();

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

	/// @notice Deposits funds from a user into the treasury, tracking the inflow for global PNL
	/// @dev Accepts both COIN_ADDRESS and CREDIT_TOKEN_ADDRESS.
	///      Credit deposits are converted to coin-equivalent for PNL tracking.
	/// @param user Address of the user depositing
	/// @param token Address of the token (must be COIN_ADDRESS or CREDIT_TOKEN_ADDRESS)
	/// @param amount Amount to deposit (in token's native decimals)
	function depositFor(address user, address token, uint256 amount) external onlyWhitelisted {
		if (user == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		if (token != COIN_ADDRESS && token != CREDIT_TOKEN_ADDRESS) revert InvalidToken();

		// LAYER 2 — credit deposit caps, checked before transfer to fail fast.
		// Prevents a compromised credit token from inflating the PNL inflow window,
		// which would otherwise allow draining USDC up to the global PNL cap.
		if (token == CREDIT_TOKEN_ADDRESS) {
			uint256 new_credit_balance = IERC20(CREDIT_TOKEN_ADDRESS).balanceOf(address(this)) + amount;

			// 2a: absolute ceiling — no matter how many credits are minted by an attacker,
			//     the treasury will never hold more than this many credit tokens.
			uint256 abs_cap = max_credit_balance;
			if (abs_cap > 0 && new_credit_balance > abs_cap) revert CreditCapExceeded();

			// 2b: ratio ceiling — credits (USDC-equivalent) cannot exceed X% of coin_balance,
			//     bounding fake PNL reduction to a fraction of the real treasury.
			uint16 ratio_bps = max_credit_coin_ratio_bps;
			if (ratio_bps > 0 && _creditToCoin(new_credit_balance) > coin_balance * ratio_bps / BPS_DENOMINATOR) {
				revert CreditRatioExceeded();
			}
		}

		IERC20(token).safeTransferFrom(user, address(this), amount);

		// Convert to coin decimals for PNL tracking (LAYER 4 inflow)
		uint256 pnl_amount = token == CREDIT_TOKEN_ADDRESS ? _creditToCoin(amount) : amount;

		uint256 today = block.timestamp / DAY_DURATION;
		_recordBucket(global_inflows_window, today, pnl_amount);

		// LAYER 1 — only real coin increments the internal balance tracker
		if (token == COIN_ADDRESS) {
			coin_balance += amount;
		}

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

		// Convert to coin-equivalent for cap checks and PNL tracking
		uint256 pnl_amount = token == CREDIT_TOKEN_ADDRESS ? _creditToCoin(amount) : amount;

		uint256 today = block.timestamp / DAY_DURATION;

		// Snapshot coin_balance once per day so all BPS limits are order-independent.
		// Without this, each payout would lower the balance and shrink the remaining
		// limit for subsequent payouts in the same day.
		//
		// Encoding: stored as (coin_balance + 1) so that 0 unambiguously means
		// "no snapshot taken today" — even when the real balance is 0.
		// A stored value of 1 decodes to a balance of 0; 101 decodes to 100; etc.
		DayBucket storage snap = daily_balance_snapshot;
		uint256 balance;
		if (snap.day_index == today && snap.amount != 0) {
			balance = snap.amount - 1;
		} else {
			balance = coin_balance;
			snap.amount = balance + 1;
			snap.day_index = today;
		}

		// Single SLOAD for all BPS caps
		BpsCaps memory c = bps_caps;

		// LAYER 4 — global 14-day rolling PNL cap.
		// Accumulates all outflows and inflows over a 14-day window. If net outflow
		// (outflows minus inflows) would exceed X% of today's opening balance, revert.
		// This limits the total damage from a sustained multi-day attack and is
		// naturally whale-friendly: large user deposits increase inflows and reduce net PNL.
		if (c.max_global_pnl_bps > 0) {
			uint256 window_out = _windowSum(global_outflows_window) + pnl_amount;
			uint256 window_in = _windowSum(global_inflows_window);
			uint256 pnl = window_out > window_in ? window_out - window_in : 0;
			uint256 bps_limit = balance * c.max_global_pnl_bps / BPS_DENOMINATOR;
			if (pnl > bps_limit) revert GlobalPnlExceeded();
		}

		// Record outflow into the 14-day window (LAYER 4) and update internal balance (LAYER 1)
		_recordBucket(global_outflows_window, today, pnl_amount);

		if (token == COIN_ADDRESS) {
			coin_balance -= amount;
		}

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

	/// @notice Deposits coin funds into treasury, tracking the balance internally
	/// @dev Must be called instead of a direct transfer to maintain coin_balance accuracy (LAYER 1).
	///      Only accepts COIN_ADDRESS — credit tokens cannot be deposited by the owner.
	/// @param amount Amount to deposit (in coin decimals)
	function deposit(uint256 amount) external onlyOwner {
		if (amount == 0) revert InvalidInput();
		IERC20(COIN_ADDRESS).safeTransferFrom(msg.sender, address(this), amount);
		coin_balance += amount;
		emit Deposited(msg.sender, msg.sender, COIN_ADDRESS, amount);
	}

	/// @notice Withdraws real token funds from treasury with daily cap
	/// @param to Address to send funds to
	/// @param amount Amount to withdraw (in coin decimals)
	function withdraw(address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		// LAYER 5 — admin daily withdrawal cap.
		// Limits damage if the owner multisig is compromised. Uses the same daily balance
		// snapshot as drain() so the limit is order-independent with Machine payouts.
		uint256 cap_bps = bps_caps.admin_daily_withdraw_bps;
		if (cap_bps > 0) {
			uint256 today = block.timestamp / DAY_DURATION;

			// Same +1 bias encoding as in drain() — see comment there.
			DayBucket storage snap = daily_balance_snapshot;
			uint256 balance;
			if (snap.day_index == today && snap.amount != 0) {
				balance = snap.amount - 1;
			} else {
				balance = coin_balance;
				snap.amount = balance + 1;
				snap.day_index = today;
			}

			DayBucket storage aw = admin_withdrawn_today;
			uint256 today_withdrawn = (aw.day_index == today ? aw.amount : 0) + amount;
			uint256 daily_limit = balance * cap_bps / BPS_DENOMINATOR;
			if (today_withdrawn > daily_limit) revert AdminWithdrawExceeded();

			aw.amount = today_withdrawn;
			aw.day_index = today;
		}

		// LAYER 1 — keep internal balance in sync
		coin_balance -= amount;
		IERC20(COIN_ADDRESS).safeTransfer(to, amount);
		emit FundsWithdrawn(to, amount);
	}

	/// @notice Withdraws credit tokens from treasury to a given address
	/// @dev No cap applies — credit tokens are not tracked treasury capital.
	///      Use burnCredit() (whitelisted machines) to destroy credits instead.
	/// @param to Address to send credit tokens to
	/// @param amount Amount of credit tokens to withdraw (18 decimals)
	function withdrawCredit(address to, uint256 amount) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();
		IERC20(CREDIT_TOKEN_ADDRESS).safeTransfer(to, amount);
		emit CreditWithdrawn(to, amount);
	}

	/// @notice Sweeps USDC sent directly to the contract outside of deposit()/depositFor()
	/// @dev coin_balance only tracks funds deposited through the contract's own methods.
	///      Any USDC transferred directly (e.g. by mistake) is excess and cannot be recovered
	///      via withdraw() because that decrements coin_balance. This function transfers only
	///      the difference: balanceOf - coin_balance.
	///      Does not touch coin_balance or daily_balance_snapshot — excess is not tracked funds.
	///      Bypasses admin_daily_withdraw_bps intentionally: excess is not treasury capital.
	/// @param to Address to send excess USDC to
	function withdrawExcessCoin(address to) external onlyOwner {
		if (to == address(0)) revert InvalidInput();

		uint256 actual_balance = IERC20(COIN_ADDRESS).balanceOf(address(this));
		uint256 excess = actual_balance > coin_balance ? actual_balance - coin_balance : 0;
		if (excess == 0) revert InvalidInput();

		IERC20(COIN_ADDRESS).safeTransfer(to, excess);
		emit ExcessCoinWithdrawn(to, excess);
	}

	/// @notice Recovers ERC20 tokens accidentally sent to this contract
	/// @dev Only for tokens other than COIN_ADDRESS and CREDIT_TOKEN_ADDRESS.
	///      Use withdrawExcessCoin() for stranded USDC and burnCredit() for credit tokens.
	/// @param token Address of the ERC20 token to recover
	/// @param to Address to send the recovered tokens to
	function recoverToken(address token, address to) external onlyOwner {
		if (to == address(0)) revert InvalidInput();
		if (token == COIN_ADDRESS) revert InvalidToken();
		if (token == CREDIT_TOKEN_ADDRESS) revert InvalidToken();

		uint256 balance = IERC20(token).balanceOf(address(this));
		if (balance == 0) revert InvalidInput();

		IERC20(token).safeTransfer(to, balance);
		emit TokenRecovered(token, to, balance);
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

	/// @notice Sets the absolute cap on credit tokens held in treasury (0 = unlimited)
	/// @dev See LAYER 2a. Recommended: set to a multiple of your expected max credit bet size.
	/// @param amount Max credit token balance in credit token decimals (18)
	function setMaxCreditBalance(uint256 amount) external onlyOwner {
		max_credit_balance = amount;
	}

	/// @notice Sets the credit/coin ratio cap (0 = unlimited)
	/// @dev See LAYER 2b. Example: 1000 = credits held (USDC-equivalent) ≤ 10% of coin_balance.
	/// @param bps Max credit coin-equivalent as % of coin_balance in BPS
	function setMaxCreditCoinRatioBps(uint16 bps) external onlyOwner {
		if (bps > BPS_DENOMINATOR) revert InvalidBps();
		max_credit_coin_ratio_bps = bps;
	}

	/// @notice Updates all BPS-based rate-limit caps in a single SSTORE
	/// @dev See LAYERS 4, 5. Setting a field to 0 disables that cap.
	/// @param _caps New BPS caps configuration
	function updateBpsCaps(BpsCaps calldata _caps) external onlyOwner {
		if (_caps.max_global_pnl_bps > BPS_DENOMINATOR) revert InvalidBps();
		if (_caps.admin_daily_withdraw_bps > BPS_DENOMINATOR) revert InvalidBps();
		bps_caps = _caps;
		emit BpsCapsUpdated(_caps.max_global_pnl_bps, _caps.admin_daily_withdraw_bps);
	}

	// ─── View Functions ───

	/// @notice Returns the internally tracked coin balance (LAYER 1)
	function getBalance() external view returns (uint256) {
		return coin_balance;
	}

	/// @notice Returns the current global net PNL over the rolling 14-day window (in coin decimals)
	function getGlobalPnl() external view returns (uint256) {
		uint256 window_out = _windowSum(global_outflows_window);
		uint256 window_in = _windowSum(global_inflows_window);
		return window_out > window_in ? window_out - window_in : 0;
	}

	/// @notice Returns today's admin withdrawal total (in coin decimals)
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

	/// @dev Sums the last 14 days of a bucket array (rolling window).
	///      Each slot holds one day's total. Slot index = day_index % 14.
	///      A slot is considered stale (and skipped) if its stored day_index differs from
	///      the expected day, meaning it was last written more than 14 days ago.
	function _windowSum(DayBucket[14] storage buckets) internal view returns (uint256) {
		uint256 today = block.timestamp / DAY_DURATION;
		uint256 total = 0;
		for (uint256 i = 0; i < WINDOW_DAYS; ++i) {
			// Guard against uint256 underflow when today < i.
			// Unreachable on mainnet (today > 20_000), but necessary for day-0 correctness
			// and to prevent test environments with block.timestamp near 0 from panicking.
			if (i > today) break;
			uint256 target_day = today - i;
			uint256 slot = target_day % WINDOW_DAYS;
			if (buckets[slot].day_index == target_day) {
				total += buckets[slot].amount;
			}
		}
		return total;
	}

	/// @dev Records an amount into today's bucket, resetting if stale.
	///      Slot reuse is safe because any slot whose stored day_index != today is treated as 0.
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
