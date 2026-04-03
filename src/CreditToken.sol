// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICreditToken} from "./ICreditToken.sol";

/// @title CreditToken
/// @notice ERC20 token that can be minted by the owner for credit-based betting
/// @dev Only whitelisted addresses can transfer tokens, and they have permanent approval
/// @dev Burn Mechanics:
///      - burn(): Only whitelisted addresses can call, burns from their own balance (msg.sender)
///      - masterBurn(): Only owner can call, can burn from any address (for emergency/admin purposes)
contract CreditToken is ERC20, Ownable, ICreditToken {
	/// @notice Mapping of whitelisted addresses that can transfer tokens
	mapping(address => bool) public whitelisted_addresses;

	event AddressWhitelisted(address indexed addr);
	event AddressRemovedFromWhitelist(address indexed addr);
	event MasterBurn(address indexed from, uint256 amount);

	error Unauthorized();
	error InvalidAddress();
	error NotSupported();

	constructor(address _owner) ERC20("Credit Token", "CREDIT") Ownable(_owner) {}

	/// @notice Adds an address to the whitelist
	/// @dev Can only be called by owner
	/// @param addr Address to whitelist
	function addToWhitelist(address addr) external onlyOwner {
		if (addr == address(0)) revert InvalidAddress();
		whitelisted_addresses[addr] = true;
		emit AddressWhitelisted(addr);
	}

	/// @notice Removes an address from the whitelist
	/// @dev Can only be called by owner
	/// @param addr Address to remove from whitelist
	function removeFromWhitelist(address addr) external onlyOwner {
		whitelisted_addresses[addr] = false;
		emit AddressRemovedFromWhitelist(addr);
	}

	/// @notice Mints new credit tokens
	/// @dev Can only be called by owner
	/// @param to Address to mint tokens to
	/// @param amount Amount of tokens to mint
	function mint(address to, uint256 amount) external onlyOwner {
		_mint(to, amount);
	}

	/// @notice Burns credit tokens from the caller's own balance
	/// @dev Can only be called by whitelisted addresses. Burns from msg.sender's balance.
	/// @param amount Amount of tokens to burn
	function burn(uint256 amount) external {
		if (!whitelisted_addresses[msg.sender]) revert Unauthorized();
		_burn(msg.sender, amount);
	}

	/// @notice Burns credit tokens from any address
	/// @dev Can only be called by owner. Owner can burn from any address.
	/// @param from Address to burn tokens from
	/// @param amount Amount of tokens to burn
	function masterBurn(address from, uint256 amount) external onlyOwner {
		if (from == address(0)) revert InvalidAddress();
		_burn(from, amount);
		emit MasterBurn(from, amount);
	}

	/// @notice Disabled — this token does not use the standard ERC20 approval model
	/// @dev Whitelisted addresses have implicit permanent approval via the whitelist
	function approve(address, uint256) public pure override returns (bool) {
		revert NotSupported();
	}

	/// @notice Override allowance to provide permanent approval to whitelisted addresses
	/// @dev Whitelisted addresses always have max approval
	function allowance(address owner, address spender) public view override returns (uint256) {
		if (whitelisted_addresses[spender]) {
			return type(uint256).max;
		}
		return super.allowance(owner, spender);
	}

	/// @notice Override transfer to only allow whitelisted addresses
	/// @dev Only whitelisted addresses can initiate transfers
	function transfer(address to, uint256 value) public override returns (bool) {
		if (!whitelisted_addresses[msg.sender]) revert Unauthorized();
		return super.transfer(to, value);
	}

	/// @notice Override transferFrom to only allow whitelisted addresses
	/// @dev Only whitelisted addresses can call transferFrom. All other calls are blocked.
	function transferFrom(address from, address to, uint256 value) public override returns (bool) {
		if (!whitelisted_addresses[msg.sender]) revert Unauthorized();
		_transfer(from, to, value);
		return true;
	}
}
