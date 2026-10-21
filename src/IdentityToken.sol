// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract IdentityToken is ERC20 {
    address public engine;
    uint256 public tokenId;

    constructor(string memory name, string memory symbol, address _engine, uint256 _id) ERC20(name, symbol) {
        engine = _engine;
        tokenId = _id;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        require(msg.sender == engine, "SOULBOUND: cannot transfer");
        return super.transfer(to, amount);
    }
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        require(msg.sender == engine, "SOULBOUND: cannot transfer");
        return super.transferFrom(from, to, amount);
    }
}
