// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/SafeCast.sol";
import "../interfaces/IRewarder.sol";
import "../codes/Ownable.sol";
import "../CLA/ClaimToken.sol";
import "../interfaces/IMiningTreasury.sol";

/**
 * @title CLA MasterChef of CLS.
 * distribute CLA tokens to CLS holders
 *
 *
 * References:
 *
 * - https://github.com/sushiswap/sushiswap/blob/canary/contracts/MasterChefV2.sol
 */
contract ClaDistributor is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    struct PoolInfo {
        uint256 accClaPerShare;
        uint256 lastRewardBlock;
    }

    /// @notice Info of each user's rewardDebt.
    /// `rewardDebt` The amount of CLA entitled to the user.
    mapping(address => int256) public rewardDebt;
    /// @notice Address of CLS contract.
    address public cls;
    /// @notice Address of CLA contract.
    ClaimToken public cla;
    /// @notice treasury address of CLA tokens.
    IMiningTreasury public miningTreasury;
    /// @notice Address of `IRewarder` contract.
    IRewarder public rewarder;
    /// @notice Info of pool.
    PoolInfo public poolInfo;

    /// @notice Block at the start of CLA mining
    uint256 public startBlock;
    /// @notice Reward ratio between LP staker and CLA staker
    uint256 public clsRewardRatio;
    uint256 public bonusEndBlock;
    uint256 private constant BONUS_MULTIPLIER = 2;
    uint256 private constant CLA_REWARD_RATIO_DIVISOR = 1e12;
    uint256 private constant ACC_CLA_PRECISION = 1e12;
    uint256 private constant YEAR = 12 * 30 * 24 * 60 * 60;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 amount, address indexed to);
    event UpdatePool(uint256 clsSupply, uint256 accClaPerShare);
    event UpdateClsRewardRatio(uint256 clsRewardRatio);
    event SetRewarder(address indexed rewarder);

    /// @param cls_ The CLS token contract address.
    /// @param cla_ The CLA token contract address.
    /// @param miningTreasury_ Contract address of CLA treasury.
    /// @param rewarder_ Contract address of Airdroper.
    /// @param startBlock_ Start block of masterChef. (must be same to masterChef's one)
    /// @param migrationEndBlock_ Migration end block of masterChef. (must be same to masterChef's one)
    constructor(
        address cls_,
        ClaimToken cla_,
        IMiningTreasury miningTreasury_,
        IRewarder rewarder_,
        uint256 startBlock_,
        uint256 migrationEndBlock_
    ) public {
        cls = cls_;
        cla = cla_;
        miningTreasury = miningTreasury_;
        rewarder = rewarder_;
        poolInfo.lastRewardBlock = migrationEndBlock_;
        startBlock = startBlock_;
        bonusEndBlock = migrationEndBlock_.add(
            migrationEndBlock_.sub(startBlock_)
        );
    }

    /// @notice Number of tokens created per block.
    function claPerBlock() public view returns (uint256) {
        return _claPerBlock(block.number);
    }

    /// @notice Number of tokens created per block.
    function _claPerBlock(uint256 blockNumber) internal view returns (uint256) {
        if (blockNumber < startBlock + 2 * YEAR) {
            return ((9e17 / CLA_REWARD_RATIO_DIVISOR) * clsRewardRatio);
        } else if (blockNumber < startBlock + 2 * 2 * YEAR) {
            return ((6e17 / CLA_REWARD_RATIO_DIVISOR) * clsRewardRatio);
        } else if (blockNumber < startBlock + 2 * 3 * YEAR) {
            return ((3e17 / CLA_REWARD_RATIO_DIVISOR) * clsRewardRatio);
        } else {
            return 0;
        }
    }

    /// @notice Number of tokens created between the given _from to _to blocks.
    function claPerBlocks(uint256 from, uint256 to)
        public
        view
        returns (uint256)
    {
        require(from <= to);
        if (from < bonusEndBlock) {
            uint256 claPerBlockFrom = _claPerBlock(from).mul(BONUS_MULTIPLIER);
            uint256 claPerBlockTo = _claPerBlock(to);
            if (to <= bonusEndBlock) {
                return to.sub(from).mul(claPerBlockFrom);
            }
            return
                claPerBlockFrom.mul(bonusEndBlock.sub(from)).add(
                    claPerBlockTo.mul(to.sub(bonusEndBlock))
                );
        } else {
            uint256 claPerBlockFrom = _claPerBlock(from);
            uint256 claPerBlockTo = _claPerBlock(to);
            if (claPerBlockFrom == claPerBlockTo)
                return to.sub(from).mul(claPerBlockFrom);
            uint256 boundary = (to.sub(startBlock) / (2 * YEAR)).mul(2 * YEAR).add(
                startBlock
            );
            return
                claPerBlockFrom.mul(boundary.sub(from)).add(
                    claPerBlockTo.mul(to.sub(boundary))
                );
        }
    }

    /// @notice Set cls reward ratio.
    /// @param clsRewardRatio_ Cls reward ratio.
    /// @param withUpdate Update pool flag.
    function setClsRewardRatio(uint256 clsRewardRatio_, bool withUpdate)
        public
    {
        require(msg.sender == address(miningTreasury), "not mining treasury");
        if (withUpdate) {
            updatePool();
        }
        clsRewardRatio = clsRewardRatio_;
        emit UpdateClsRewardRatio(clsRewardRatio);
    }

    /// @notice View function to see pending CLA.
    /// @param user Address of user.
    /// @return Pending CLA reward for a given user.
    function pendingCla(address user) external view returns (uint256 pending) {
        uint256 accClaPerShare = poolInfo.accClaPerShare;
        uint256 clsSupply = IERC20(cls).totalSupply();
        if (block.number > poolInfo.lastRewardBlock && clsSupply != 0) {
            uint256 claReward = claPerBlocks(
                poolInfo.lastRewardBlock,
                block.number
            );

            if (claReward != 0) {
                accClaPerShare = accClaPerShare.add(
                    (claReward.mul(ACC_CLA_PRECISION) / clsSupply)
                );
            }
        }
        pending = int256(
            IERC20(cls).balanceOf(user).mul(accClaPerShare) / ACC_CLA_PRECISION
        ).sub(rewardDebt[user]).toUint256();
    }

    /// @notice Update accumulated reward per block of the pool.
    function updatePool() public {
        if (block.number > poolInfo.lastRewardBlock) {
            uint256 clsSupply = IERC20(cls).totalSupply();
            if (clsSupply > 0) {
                uint256 claReward = claPerBlocks(
                    poolInfo.lastRewardBlock,
                    block.number
                );

                if (claReward != 0) {
                    miningTreasury.transfer(claReward);
                    poolInfo.accClaPerShare = poolInfo.accClaPerShare.add(
                        (claReward.mul(ACC_CLA_PRECISION) / clsSupply)
                    );
                }
            }
            poolInfo.lastRewardBlock = block.number;
            emit UpdatePool(clsSupply, poolInfo.accClaPerShare);
        }
    }

    /// @notice Deposit CLS tokens.
    /// @param user The receiver of `amount` deposit benefit.
    /// @param amount CLS token amount to deposit.
    function deposit(address user, uint256 amount) public {
        require(msg.sender == cls);
        updatePool();
        rewardDebt[user] = rewardDebt[user].add(
            int256(amount.mul(poolInfo.accClaPerShare) / ACC_CLA_PRECISION)
        );

        IRewarder _rewarder = rewarder;
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(0, user, user, 0, IERC20(cls).balanceOf(user));
        }

        emit Deposit(user, amount);
    }

    /// @notice Withdraw CLS tokens.
    /// @param user Receiver of the CLS tokens.
    /// @param amount CLS token amount to withdraw.
    function withdraw(address user, uint256 amount) public {
        require(msg.sender == cls);
        updatePool();
        rewardDebt[user] = rewardDebt[user].sub(
            int256(amount.mul(poolInfo.accClaPerShare) / ACC_CLA_PRECISION)
        );

        IRewarder _rewarder = rewarder;
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(0, user, user, 0, IERC20(cls).balanceOf(user));
        }
        emit Withdraw(user, amount);
    }

    /// @dev Harvest proceeds for transaction sender to `to`.
    /// @param to Receiver of CLA rewards.
    function harvest(address to) public {
        updatePool();
        PoolInfo memory pool = poolInfo;
        int256 accumulatedCla = int256(
            IERC20(cls).balanceOf(msg.sender).mul(pool.accClaPerShare) /
                ACC_CLA_PRECISION
        );
        uint256 _pendingCla = accumulatedCla
            .sub(rewardDebt[msg.sender])
            .toUint256();
        rewardDebt[msg.sender] = accumulatedCla;
        if (_pendingCla != 0) {
            _safeClaTransfer(to, _pendingCla);
        }
        IRewarder _rewarder = rewarder;
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(
                0,
                msg.sender,
                to,
                _pendingCla,
                IERC20(cls).balanceOf(msg.sender)
            );
        }
        emit Harvest(msg.sender, _pendingCla, to);
    }

    /// @notice Safe CLA transfer function, just in case if rounding error causes pool to not have enough CLAs.
    /// @param to Address of cla reciever
    /// @param amount Amount of cla to transfer
    function _safeClaTransfer(address to, uint256 amount) internal {
        uint256 claBalance = cla.balanceOf(address(this));
        if (amount > claBalance) {
            cla.transfer(to, claBalance);
        } else {
            cla.transfer(to, amount);
        }
    }

    /// @notice Set Rewarder (airdroper)
    function setRewarder(IRewarder rewarder_) public onlyOwner {
        rewarder = rewarder_;
        emit SetRewarder(address(rewarder));
    }

    /// @notice Set MiningTreasury
    function setMiningTreasury(IMiningTreasury miningTreasury_) public onlyOwner {
        miningTreasury = miningTreasury_;
    }
}
