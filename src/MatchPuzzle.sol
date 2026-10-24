// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MatchPuzzle {
    uint256 public size;
    uint256[] public grid;
    address public architect;

    event TileSwapped(uint256 posA, uint256 posB, uint256 valueA, uint256 valueB);

    constructor(uint256 _size) {
        size = _size;
        architect = msg.sender;
        // NEW GRID: Visually distinct, but mathematically matched by % 3
        // 1, 4, 2
        // 5, 7, 3
        // 6, 9, 8
        // Notice: 1%3=1, 4%3=1 (match!). 5%3=2, 2%3=2 (match!). 
        grid = [1, 4, 2, 5, 7, 3, 6, 9, 8];
    }

    function isAdjacent(uint256 posA, uint256 posB) internal view returns (bool) {
        uint256 rowA = posA / size;
        uint256 colA = posA % size;
        uint256 rowB = posB / size;
        uint256 colB = posB % size;

        if (rowA == rowB && (colA + 1 == colB || colB + 1 == colA)) return true;
        if (colA == colB && (rowA + 1 == rowB || rowB + 1 == rowA)) return true;
        return false;
    }

    function slide(uint256 fromPos, uint256 toPos) external {
        require(fromPos < grid.length && toPos < grid.length, "Out of bounds");
        require(isAdjacent(fromPos, toPos), "Not adjacent");

        uint256 valA = grid[fromPos];
        uint256 valB = grid[toPos];

        // THE GATE: Check if they share the same Modulo 3 hash
        require((valA % 3) == (valB % 3), "RESTRICTED: Hashes do not match. Slide blocked.");

        grid[fromPos] = valB;
        grid[toPos] = valA;

        emit TileSwapped(fromPos, toPos, valA, valB);
    }

    function getGrid() external view returns (uint256[] memory) {
        return grid;
    }
}
