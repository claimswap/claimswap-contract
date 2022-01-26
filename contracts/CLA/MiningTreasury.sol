// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../codes/Ownable.sol";

interface IClaDistributor {
    function setClsRewardRatio(uint256, bool) external;
}

interface IMasterChef {
    function setLpRewardRatio(uint256, bool) external;
}

contract MiningTreasury is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public cla;
    /// @notice CLA distributor address for CLS holders.
    IClaDistributor public claDistributor;
    /// @notice masterChef address for CLA LP farm.
    IMasterChef public masterChef;
    /// @notice ratio address.
    address public ratioSetter;
    /// @notice Reward ratio between LP staker and CLA staker
    uint256 private constant CLA_REWARD_RATIO_DIVISOR = 1e12;

    event LogSetClaRewardRatio(uint256 clsRewardRatio);

    function setCla(IERC20 cla_) public {
        require(address(cla) == address(0), "cla is already set");
        cla = cla_;
    }

    function transfer(uint256 amount) public {
        require(
            (address(claDistributor) == msg.sender) ||
                (address(masterChef) == msg.sender),
            "Ownable: caller is not the masterChef||claDistributor"
        );
        cla.safeTransfer(msg.sender, amount);
    }

    function setClsRewardRatio(uint256 clsRewardRatio, bool withUpdate) public {
        require(
            (owner() == msg.sender) || (ratioSetter == msg.sender),
            "Ownable: caller is not the owner||ratioSetter"
        );
        require(
            clsRewardRatio <= CLA_REWARD_RATIO_DIVISOR,
            "claRewardRatio should be lower than CLA_REWARD_RATIO_DIVISOR"
        );

        uint256 lpRewardRatio = CLA_REWARD_RATIO_DIVISOR - clsRewardRatio;

        masterChef.setLpRewardRatio(lpRewardRatio, withUpdate);
        if (address(claDistributor) != address(0)) {
            claDistributor.setClsRewardRatio(clsRewardRatio, withUpdate);
        }

        emit LogSetClaRewardRatio(clsRewardRatio);
    }

    // Update multiplier address by the previous dev.
    function setRatioSetter(address ratioSetter_) public {
        require(
            (owner() == msg.sender) || (ratioSetter == msg.sender),
            "ratioSetter: wut?"
        );
        ratioSetter = ratioSetter_;
    }

    function setClaDistributor(IClaDistributor claDistributor_)
        public
        onlyOwner
    {
        claDistributor = claDistributor_;
    }

    function setMasterChef(IMasterChef masterChef_) public onlyOwner {
        masterChef = masterChef_;
    }
}
