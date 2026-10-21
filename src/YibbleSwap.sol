// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract YibbleSwap is Ownable {
    using SafeERC20 for IERC20;
    IERC20 public yipUSD;
    IERC20 public yibbleUSD;
    uint256 public constant SWAP_FEE_BPS = 10; // 0.10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    constructor(address _yp, address _yb) Ownable(msg.sender) {
        yipUSD = IERC20(_yp);
        yibbleUSD = IERC20(_yb);
    }

    function swap(uint256 amountIn) external {
        require(amountIn > 0, "Zero amount");
        uint256 fee = (amountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountOut = amountIn - fee;

        yipUSD.safeTransferFrom(msg.sender, address(this), amountIn);
        yibbleUSD.safeTransfer(msg.sender, amountOut);
    }
    
    function withdrawFees(address to) external onlyOwner {
        yipUSD.safeTransfer(to, yipUSD.balanceOf(address(this)));
    }
    
    function seedLiquidity(uint256 amount) external onlyOwner {
        yibbleUSD.safeTransferFrom(msg.sender, address(this), amount);
    }
}
