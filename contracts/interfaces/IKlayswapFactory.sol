// SPDX-License-Identifier: MIT
pragma solidity 0.5.6;

interface IKlayswapFactory {
    function name() external view returns (string memory);

    function approve(address _spender, uint256 _value) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function transfer(address _to, uint256 _value) external returns (bool);

    function createFee() external view returns (uint256);

    function getPoolAddress(uint idx) external view returns (address);

    function getAmountData(uint si, uint ei) external view returns (uint[] memory, uint[] memory, uint[] memory);

    function createKlayPool(address token, uint amount, uint fee) external payable;

    function createKctPool(address tokenA, uint amountA, address tokenB, uint amountB, uint fee) external;

    function exchangeKlayPos(address token, uint amount, address[] calldata path) external payable;

    function exchangeKctPos(address tokenA, uint amountA, address tokenB, uint amountB, address[] calldata path) external;

    function exchangeKlayNeg(address token, uint amount, address[] calldata path) external payable;

    function exchangeKctNeg(address tokenA, uint amountA, address tokenB, uint amountB, address[] calldata path) external;
}
