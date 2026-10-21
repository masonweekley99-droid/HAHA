// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract YibbleVault is ERC4626, Ownable {
    uint256 public constant MANAGEMENT_FEE_BPS = 20; // 0.20%
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant YEAR = 365 days;
    uint256 public lastFeeAccrual;

    constructor(IERC20 asset) 
        ERC4626(asset) 
        ERC20("Yibble Share", "YIB") 
        Ownable(msg.sender) 
    {
        lastFeeAccrual = block.timestamp;
    }

    function decimals() public view override returns (uint8) { return 18; }

    function chargeManagementFee() external onlyOwner {
        uint256 timePassed = block.timestamp - lastFeeAccrual;
        if (timePassed == 0) return;
        
        uint256 currentAssets = totalAssets();
        uint256 fee = (currentAssets * MANAGEMENT_FEE_BPS * timePassed) / (FEE_DENOMINATOR * YEAR);
        
        if (fee > 0) {
            IERC20(asset()).transfer(msg.sender, fee);
        }
        lastFeeAccrual = block.timestamp;
    }
}
