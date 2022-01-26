pragma solidity 0.5.6;

interface IWKLAY {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}
