// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract YipUSD is ERC20, Ownable {
    constructor() ERC20("Yipple USD", "ypUSD") Ownable(msg.sender) {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}
