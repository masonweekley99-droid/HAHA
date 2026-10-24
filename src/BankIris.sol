// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BankIris {
    address public architect;
    IERC20 public verusToken;
    uint256 public totalAbsorbed;

    event LiquidityAbsorbed(address indexed source, uint256 amount);

    constructor(address _vrt) {
        architect = msg.sender;
        verusToken = IERC20(_vrt);
    }

    // The Bleed Feed: Only the Engine can send funds here
    function absorb(uint256 amount) external {
        require(verusToken.transferFrom(msg.sender, address(this), amount), "Absorption failed");
        totalAbsorbed += amount;
        emit LiquidityAbsorbed(msg.sender, amount);
    }

    // Architect can only withdraw if they want to move the vault (optional)
    function withdraw(uint256 amount) external {
        require(msg.sender == architect, "Only the Architect");
        verusToken.transfer(architect, amount);
    }
}
