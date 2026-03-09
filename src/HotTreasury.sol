// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditToken} from "./ICreditToken.sol";

/// @title HotTreasury - Centralized Treasury for Betting Contracts
/// @notice Manages funds for multiple betting contracts from a single source
/// @dev Whitelists contracts that can drain funds, owner can withdraw
/// @dev Supports any ERC20 token, with specific credit token for burning
/// @dev Deployment Steps:
///      1. Deploy HotTreasury with credit token address
///      2. Deploy ComboMachine(s) with treasury address (must use same credit token)
///      3. Call treasury.addToWhitelist(comboMachineAddress) for each betting contract
///      4. Fund the treasury with tokens
///      5. Betting contracts can now drain funds for payouts/refunds
contract HotTreasury is Ownable {
	using SafeERC20 for IERC20;

	/// @notice Address of the credit token used for burning (immutable)
	address public immutable CREDIT_TOKEN_ADDRESS;

	/// @notice Mapping of whitelisted contracts that can drain funds
	mapping(address => bool) public whitelisted_contracts;

	event ContractWhitelisted(address indexed contract_address);
	event ContractRemovedFromWhitelist(address indexed contract_address);
	event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);
	event FundsDrained(
		address indexed contract_address,
		address indexed token,
		address indexed to,
		uint256 amount
	);
	event CreditBurned(address indexed contract_address, uint256 amount);

	error Unauthorized();
	error InvalidInput();
	error TransferFailed();

	/// @dev Modifier to restrict access to whitelisted contracts only
	modifier onlyWhitelisted() {
		if (!whitelisted_contracts[msg.sender]) revert Unauthorized();
		_;
	}

	/// @notice Initializes the treasury with credit token
	/// @param _CREDIT_TOKEN_ADDRESS Address of the credit token for burning
	/// @param _owner Address that will own the contract
	constructor(address _CREDIT_TOKEN_ADDRESS, address _owner) Ownable(_owner) {
		if (_owner == address(0)) revert InvalidInput();
		if (_CREDIT_TOKEN_ADDRESS == address(0)) revert InvalidInput();
		if (IERC20Metadata(_CREDIT_TOKEN_ADDRESS).decimals() != 18) revert InvalidInput();

		CREDIT_TOKEN_ADDRESS = _CREDIT_TOKEN_ADDRESS;
	}

	/// @notice Adds a contract to the whitelist
	/// @dev Can only be called by contract owner
	/// @param contract_address Address of the contract to whitelist
	function addToWhitelist(address contract_address) external onlyOwner {
		if (contract_address == address(0)) revert InvalidInput();
		whitelisted_contracts[contract_address] = true;
		emit ContractWhitelisted(contract_address);
	}

	/// @notice Removes a contract from the whitelist
	/// @dev Can only be called by contract owner
	/// @param contract_address Address of the contract to remove
	function removeFromWhitelist(address contract_address) external onlyOwner {
		whitelisted_contracts[contract_address] = false;
		emit ContractRemovedFromWhitelist(contract_address);
	}

	/// @notice Drains funds from treasury to a specified address
	/// @dev Can only be called by whitelisted contracts
	/// @param token Address of the token to drain
	/// @param to Address to send funds to
	/// @param amount Amount to drain
	function drain(address token, address to, uint256 amount) external onlyWhitelisted {
		if (token == address(0)) revert InvalidInput();
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		IERC20(token).safeTransfer(to, amount);
		emit FundsDrained(msg.sender, token, to, amount);
	}

	/// @notice Burns credit tokens from treasury in a single call
	/// @dev Can only be called by whitelisted contracts. Burns credit tokens held by treasury.
	/// @param amount Amount of credit tokens to burn
	function burnCredit(uint256 amount) external onlyWhitelisted {
		if (amount == 0) revert InvalidInput();

		// Burn credit tokens directly from treasury
		ICreditToken(CREDIT_TOKEN_ADDRESS).burn(amount);

		emit CreditBurned(msg.sender, amount);
	}

	/// @notice Withdraws funds from treasury (emergency function for owner)
	/// @dev Can only be called by contract owner
	/// @param token Address of the token to withdraw
	/// @param to Address to send funds to
	/// @param amount Amount to withdraw
	function withdraw(address token, address to, uint256 amount) external onlyOwner {
		if (token == address(0)) revert InvalidInput();
		if (to == address(0)) revert InvalidInput();
		if (amount == 0) revert InvalidInput();

		IERC20(token).safeTransfer(to, amount);
		emit FundsWithdrawn(token, to, amount);
	}

	/// @notice Withdraws ETH from treasury (emergency function)
	/// @dev Can only be called by contract owner
	function withdrawEth() external onlyOwner {
		uint256 balance = address(this).balance;
		if (balance == 0) revert InvalidInput();

		(bool success, ) = msg.sender.call{value: balance}("");
		if (!success) revert TransferFailed();
	}

	/// @notice Gets the balance of a token in the treasury
	/// @param token Address of the token to check
	/// @return Balance of the token
	function getBalance(address token) external view returns (uint256) {
		return IERC20(token).balanceOf(address(this));
	}

	/// @notice Allows contract to receive ETH directly
	receive() external payable {}
}
