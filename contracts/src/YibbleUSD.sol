// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Local test stablecoin for the Yibble vault.
///         6 decimals to mirror USDC's interface. Owner-gated mint.
contract YibbleUSD is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Yibble USD", "ybUSD")
        Ownable(initialOwner)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
