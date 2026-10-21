// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IdentityToken.sol";

contract IdentityShiftEngine {
    IERC20 public verusToken;
    IERC20 public kaspaToken;
    IERC20 public frozenBitcoin;

    IdentityToken[] public identityTokens;
    uint256 public lastTick;
    uint256 public totalVerusSold;
    address public admin;

    mapping(address => mapping(uint256 => uint256)) public shiftBalances;

    event VerusSold(address indexed user, uint256 amount, uint256 dripBase);
    event TimeShift(address indexed user, uint256 newBalance);
    event BitcoinRevived(address indexed user, uint256 btcAmount);

    constructor(address _vrt, address _kas, address _btc) {
        admin = msg.sender;
        verusToken = IERC20(_vrt);
        kaspaToken = IERC20(_kas);
        frozenBitcoin = IERC20(_btc);
        lastTick = block.timestamp;

        for (uint i = 0; i < 12; i++) {
            IdentityToken t = new IdentityToken("Shift Identity", "SID", address(this), i);
            identityTokens.push(t);
        }
    }

    function simulateVerusSell(address user, uint256 amount) external {
        totalVerusSold += amount;
        uint256 dripBase = amount / 12;
        for (uint i = 0; i < 12; i++) {
            uint256 multiplier = (i + 1) * 10;
            shiftBalances[user][i] += dripBase * multiplier;
        }
        emit VerusSold(user, amount, dripBase);
    }

    function hourlyTick(address user) external {
        require(block.timestamp >= lastTick + 1 hours, "Too soon");
        lastTick = block.timestamp;
        for (uint i = 0; i < 12; i++) {
            shiftBalances[user][i] = (shiftBalances[user][i] * 101) / 100;
        }
        emit TimeShift(user, shiftBalances[user][0]);
    }

    function reviveFrozenBitcoin(uint256 btcAmount) external {
        uint256 requiredPerToken = btcAmount * 1000 * 10**18;
        for (uint i = 0; i < 12; i++) {
            require(shiftBalances[msg.sender][i] >= requiredPerToken, "Identity burn insufficient");
            shiftBalances[msg.sender][i] -= requiredPerToken;
        }
        // ✅ WBTC = 8 decimals
        require(frozenBitcoin.transfer(msg.sender, btcAmount * 10**8), "Bitcoin revive failed");
        emit BitcoinRevived(msg.sender, btcAmount);
    }
}
