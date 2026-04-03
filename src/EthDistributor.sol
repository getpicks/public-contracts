// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EthDistributor is Ownable {
	mapping(bytes32 => bool) public used_keys;

	event Distributed(bytes32 indexed idempotency_key, address[] recipients, uint256[] amounts, uint256 total);

	error IdempotencyKeyAlreadyUsed();
	error ArrayLengthMismatch();
	error InvalidInput();
	error TransferFailed();
	error IncorrectEthAmount();

	constructor(address _owner) Ownable(_owner) {}

	/// @notice Distributes ETH to a list of recipients
	/// @param idempotency_key Unique key — reverts if this key was used before
	/// @param recipients Array of recipient addresses
	/// @param amounts Array of ETH amounts in wei, one per recipient
	function distribute(
		bytes32 idempotency_key,
		address[] calldata recipients,
		uint256[] calldata amounts
	) external payable onlyOwner {
		if (used_keys[idempotency_key]) revert IdempotencyKeyAlreadyUsed();
		if (recipients.length != amounts.length) revert ArrayLengthMismatch();
		if (recipients.length == 0) revert InvalidInput();

		uint256 total = 0;
		for (uint256 i = 0; i < amounts.length; ++i) {
			total += amounts[i];
		}
		if (msg.value != total) revert IncorrectEthAmount();

		used_keys[idempotency_key] = true;

		for (uint256 i = 0; i < recipients.length; ++i) {
			if (recipients[i] == address(0)) revert InvalidInput();
			(bool success, ) = recipients[i].call{value: amounts[i]}("");
			if (!success) revert TransferFailed();
		}

		emit Distributed(idempotency_key, recipients, amounts, total);
	}

	receive() external payable {}
}
