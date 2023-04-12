pragma solidity ^0.8.10;


interface IDiamond {
    function initialize(address, address) external payable;
}