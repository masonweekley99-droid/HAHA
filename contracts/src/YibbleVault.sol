// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YibbleVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MGMT_FEE_BPS = 20; // 0.20% annual
    address public treasury;
    uint256 public lastAccrual;

    event TreasuryUpdated(address indexed prev, address indexed next);
    event FeeAccrued(uint256 amount, uint256 timestamp);

    constructor(IERC20 asset_, address treasury_, address initialOwner)
        ERC20("Yibble Stock", "YIB")
        ERC4626(asset_)
        Ownable(initialOwner)
    {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        lastAccrual = block.timestamp;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "treasury=0");
        emit TreasuryUpdated(treasury, t);
        treasury = t;
    }

    function pendingFee() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrual;
        return (totalAssets() * MGMT_FEE_BPS * elapsed) / (10_000 * 365 days);
    }

    function accrueFee() external {
        uint256 fee = pendingFee();
        if (fee > 0 && fee <= totalAssets()) {
            IERC20(asset()).safeTransfer(treasury, fee);
            emit FeeAccrued(fee, block.timestamp);
        }
        lastAccrual = block.timestamp;
    }
}
