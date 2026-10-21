// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice 1:1 swap between ypUSD (input) and ybUSD (output).
///         Treasury funds the ybUSD reserve; ypUSD received goes to treasury.
///
/// @dev    Rate is fixed at 1:1 minus a small fee (default 0.10%).
///         If ypUSD ever trades off-peg, this contract is NOT the venue
///         for that price discovery -- it is a redemption facility.
contract YibbleSwap is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable ypUSD;
    IERC20 public immutable ybUSD;
    address public treasury;
    uint16  public feeBps;           // e.g. 10 = 0.10%
    uint256 public constant MAX_FEE_BPS = 100;  // never more than 1%

    uint256 public totalYpReceived;
    uint256 public totalYbPaidOut;

    event Swapped(
        address indexed user,
        uint256 ypIn,
        uint256 ybOut,
        uint256 feeTaken
    );
    event TreasuryUpdated(address indexed prev, address indexed next);
    event FeeUpdated(uint16 prev, uint16 next);
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);

    error FeeTooHigh(uint16 fee);
    error ZeroAmount();
    error InsufficientReserve(uint256 requested, uint256 available);

    constructor(
        IERC20 ypUSD_,
        IERC20 ybUSD_,
        address treasury_,
        uint16 feeBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(ypUSD_) != address(0), "ypUSD=0");
        require(address(ybUSD_) != address(0), "ybUSD=0");
        require(treasury_ != address(0), "treasury=0");
        require(feeBps_ <= MAX_FEE_BPS, "fee too high");

        ypUSD = ypUSD_;
        ybUSD = ybUSD_;
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // ---------- user-facing ----------

    /// @notice Swap ypUSD for ybUSD at 1:1 minus fee.
    /// @param  ypAmount   amount of ypUSD to spend
    /// @param  minYbOut   slippage guard (pass 0 to disable)
    /// @return ybOut      amount of ybUSD received
    function swapYpForYb(uint256 ypAmount, uint256 minYbOut)
        external
        nonReentrant
        returns (uint256 ybOut)
    {
        if (ypAmount == 0) revert ZeroAmount();

        uint256 fee = (ypAmount * feeBps) / 10_000;
        ybOut = ypAmount - fee;

        uint256 reserve = ybUSD.balanceOf(address(this));
        if (reserve < ybOut) revert InsufficientReserve(ybOut, reserve);
        require(ybOut >= minYbOut, "slippage");

        // Pull ypUSD in, send it to treasury
        ypUSD.safeTransferFrom(msg.sender, treasury, ypAmount);

        // Send ybUSD out
        ybUSD.safeTransfer(msg.sender, ybOut);

        totalYpReceived += ypAmount;
        totalYbPaidOut   += ybOut;

        emit Swapped(msg.sender, ypAmount, ybOut, fee);
    }

    // ---------- view ----------

    /// @notice Preview a swap without executing it.
    function quote(uint256 ypAmount)
        external
        view
        returns (uint256 ybOut, uint256 fee)
    {
        fee   = (ypAmount * feeBps) / 10_000;
        ybOut = ypAmount - fee;
    }

    /// @notice Current ybUSD reserve available to pay out.
    function reserve() external view returns (uint256) {
        return ybUSD.balanceOf(address(this));
    }

    // ---------- owner ----------

    /// @notice Fund the ybUSD reserve (owner pre-approves this contract).
    function fundReserve(uint256 ybAmount) external nonReentrant {
        if (ybAmount == 0) revert ZeroAmount();
        ybUSD.safeTransferFrom(msg.sender, address(this), ybAmount);
        emit ReserveFunded(msg.sender, ybAmount);
    }

    /// @notice Withdraw excess ybUSD reserve (owner only).
    function withdrawReserve(uint256 ybAmount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        ybUSD.safeTransfer(to, ybAmount);
        emit ReserveWithdrawn(to, ybAmount);
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "treasury=0");
        emit TreasuryUpdated(treasury, t);
        treasury = t;
    }

    function setFeeBps(uint16 f) external onlyOwner {
        if (f > MAX_FEE_BPS) revert FeeTooHigh(f);
        emit FeeUpdated(feeBps, f);
        feeBps = f;
    }
}
