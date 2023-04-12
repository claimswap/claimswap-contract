pragma solidity ^0.8.10;

interface IV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairLength, uint256 swapType);
    function getAllPairs() external view returns (address[] memory);
    function allPairsLength() external view returns (uint256);
    function getPair(address[] memory tokens) public view returns (address);
    function sortToken(
        address tokenA,
        address tokenB
    ) public pure returns (address token0, address token1);
    function allPairs(uint256) external view returns (address pair);
}