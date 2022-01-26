// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;

interface IClsToken {
    function mintClaimBoost(address to, uint256 amount) external;

    function mintMigration(address to, uint256 amount) external;
}
