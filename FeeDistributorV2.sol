// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "../codes/OwnableUpgradeable.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/SafeERC20.sol";
import "../libraries/SafeCast.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IClsToken.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../proxy/Initializable.sol";
/**
 * @title MasterChef of Fee.
 * distribute swap fee to CLS holders
 *
 * References:
 * - https://github.com/sushiswap/sushiswap/blob/canary/contracts/MasterChefV2.sol
 */
contract FeeDistributorV2 is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user's rewardDebt.
    /// `rewardDebt` The amount of Fee entitled to the user.
    mapping(address => int256) public rewardDebt;

    /// @notice Info of each pool.
    /// `accFeePerShare` Accumulated fee per share, times 1e12.
    struct PoolInfo {
        uint256 accFeePerShare;
    }

    /// @notice Address of CLA contract.
    address public cla;
    /// @notice Address of CLS contract.
    address public cls;
    /// @notice Dev address.
    address public dev;
    /// @notice liquidity updater.
    address public updater;
    /// @notice Address of Router contract.
    IUniswapV2Router02 public router;

    /// @notice Info of each pool.
    PoolInfo public poolInfo;

    mapping(address => bool) public feeLp;

    uint256 private constant ACC_FEE_PRECISION = 1e24;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(
        address indexed user,
        uint256 amount,
        address indexed to
    );
    event AddLp(IUniswapV2Pair indexed feeLp);
    event RemoveLp(IUniswapV2Pair indexed feeLp);
    event UpdatePool(
        IERC20 indexed feeToken,
        uint256 clsSupply,
        uint256 accFeePerShare
    );
    event UpdateDev(address prevDev, address newDev);
    event UpdateUpdater(address prevUpdater, address newUpdater);


    function initialize(
        address cla_,
        address cls_,
        address dev_,
        IUniswapV2Router02 router_
    ) public initializer {
        __Ownable_init();
        cla = cla_;
        cls = cls_;
        dev = dev_;
        router = router_;
        emit UpdateDev(address(0), dev_);
    }

    /// @notice Add a new LP token. Can only be called by the owner.
    /// @param feeLp_ Address of the IUniswapV2Pair token.
    function addLp(IUniswapV2Pair feeLp_) public onlyOwner {
        feeLp[address(feeLp_)] = true;
        emit AddLp(feeLp_);
    }

    /// @notice Remove a LP token. Can only be called by the owner.
    /// @param feeLp_ Address of the IUniswapV2Pair token.
    function removeLp(IUniswapV2Pair feeLp_) public onlyOwner {
        delete feeLp[address(feeLp_)];
        emit RemoveLp(feeLp_);
    }

    /// @notice View function to see pending fee.
    /// @param user Address of user.
    /// @return Pending fee reward for a given user.
    function pendingFee(address user)
        external
        view
        returns (uint256 pendingFee_, uint256 pendingFeeClaimBoost)
    {
        pendingFeeClaimBoost = int256(
            IERC20(cls).balanceOf(user).mul(poolInfo.accFeePerShare) /
                ACC_FEE_PRECISION
        ).sub(rewardDebt[user]).toUint256();
        pendingFee_ = pendingFeeClaimBoost.sub(pendingFeeClaimBoost / 2);
    }

    function updatePool(
        IUniswapV2Pair feeLp_,
        uint256 token0Min,
        uint256 token1Min,
        uint256 cla0Min,
        uint256 cla1Min,
        address[] memory path0,
        address[] memory path1
    ) public {
        require(msg.sender == owner() || msg.sender == updater, "Invalid access");
        _updatePool(feeLp_, token0Min, token1Min, cla0Min, cla1Min, path0, path1);
    }

    function massUpdatePools(
        IUniswapV2Pair[] memory feeLps,
        uint256[] memory token0Mins,
        uint256[] memory token1Mins,
        uint256[] memory cla0Mins,
        uint256[] memory cla1Mins,
        address[][] memory paths0,
        address[][] memory paths1
    ) public {
        require(msg.sender == owner() || msg.sender == updater, "Invalid access");
        uint256 len = feeLps.length;
        for (uint256 i = 0; i < len; ++i) {
            _updatePool(feeLps[i], token0Mins[i], token1Mins[i], cla0Mins[i], cla1Mins[i], paths0[i], paths1[i]);
        }
    }

    function _updatePool(
        IUniswapV2Pair feeLp_,
        uint256 token0Min,
        uint256 token1Min,
        uint256 cla0Min,
        uint256 cla1Min,
        address[] memory path0,
        address[] memory path1
    ) internal {
        uint256 amount = feeLp_.balanceOf(address(this));
        if(amount > 0) {
            if (feeLp[address(feeLp_)] == true) {
                address token0 = feeLp_.token0();
                address token1 = feeLp_.token1();
                IERC20(address(feeLp_)).safeIncreaseAllowance(address(router), amount);
                (uint256 amountA, uint256 amountB) = router.removeLiquidity(
                    token0,
                    token1,
                    amount,
                    token0Min,
                    token1Min,
                    address(this),
                    uint256(-1)
                );
                _swapToCla(IERC20(token0), amountA, cla0Min, path0);
                _swapToCla(IERC20(token1), amountB, cla1Min, path1);
            }
            else{
                IERC20(address(feeLp_)).safeTransfer(dev, amount);
            }
        }
    }

    function swapToCla(IERC20 feeToken_, uint256 amount, uint256 minAmount, address[] memory path) public {
        require(msg.sender == owner() || msg.sender == updater, "Invalid access");
        feeToken_.safeTransferFrom(msg.sender, address(this), amount);
        _swapToCla(feeToken_, amount, minAmount, path);
    }

    function _swapToCla(IERC20 feeToken_, uint256 amount, uint256 minAmount, address[] memory path) internal {
        require(path.length == 0 || path[path.length - 1] == cla, "invalid path");
        if(amount > 0) {
            uint256 claAmount = amount;
            if(address(feeToken_) != cla){
                feeToken_.safeIncreaseAllowance(address(router), amount);
                uint256[] memory amounts = router.swapExactTokensForTokens(
                    amount,
                    minAmount,
                    path,
                    address(this),
                    uint256(-1)
                );
                claAmount = amounts[amounts.length - 1];
            }
            uint256 totalSupply = IERC20(cls).totalSupply();
            poolInfo.accFeePerShare = poolInfo.accFeePerShare.add(
                claAmount.mul(ACC_FEE_PRECISION) / totalSupply
            );
            emit UpdatePool(
                feeToken_,
                totalSupply,
                poolInfo.accFeePerShare
            );
        }
    }

    /// @notice Deposit CLS tokens for rewards allocation.
    /// @param user The receiver of `amount` deposit benefit.
    /// @param amount CLS token amount to deposit.
    function deposit(
        address user,
        uint256 amount
    ) public {
        require(msg.sender == cls);
        rewardDebt[user] = rewardDebt[user].add(
            int256(amount.mul(poolInfo.accFeePerShare) / ACC_FEE_PRECISION)
        );

        emit Deposit(user, amount);
    }

    /// @notice Withdraw CLS tokens.
    /// @param user Receiver of the CLS tokens.
    /// @param amount CLS token amount to withdraw.
    function withdraw(
        address user,
        uint256 amount
    ) public {
        require(msg.sender == cls);
        rewardDebt[user] = rewardDebt[user].sub(
            int256(amount.mul(poolInfo.accFeePerShare) / ACC_FEE_PRECISION)
        );

        emit Withdraw(user, amount);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param to Receiver of fee rewards.
    /// @param boost If true, all rewards are converted to CLA.
    function harvest(
        address to,
        bool boost
    ) public {
        PoolInfo memory pool = poolInfo;
        int256 accumulatedFee = int256(
            IERC20(cls).balanceOf(msg.sender).mul(pool.accFeePerShare) /
                ACC_FEE_PRECISION
        );
        uint256 _pendingFee = accumulatedFee
            .sub(rewardDebt[msg.sender])
            .toUint256();

        rewardDebt[msg.sender] = accumulatedFee;

        if (_pendingFee != 0) {
            if (!boost) {
                uint256 notBoostFee = _pendingFee / 2;
                _pendingFee = _pendingFee.sub(notBoostFee);
                _safeClaTransfer(dev, notBoostFee);
                _safeClaTransfer(to, _pendingFee);
            } else {
                IERC20(cla).safeIncreaseAllowance(cls, _pendingFee);
                IClsToken(cls).mintClaimBoost(to, _pendingFee);
            }
        }

        emit Harvest(msg.sender, _pendingFee, to);
    }

    /// @notice Safe CLA transfer function, just in case if rounding error causes pool to not have enough CLAs.
    /// @param to Address of cla reciever
    /// @param amount Amount of cla to transfer
    function _safeClaTransfer(address to, uint256 amount) internal {
        uint256 claBalance = IERC20(cla).balanceOf(address(this));
        if (amount > claBalance) {
            IERC20(cla).safeTransfer(to, claBalance);
        } else {
            IERC20(cla).safeTransfer(to, amount);
        }
    }

    // Update dev address.
    function setDev(address dev_) public {
        require(msg.sender == owner() || msg.sender == dev, "dev: wut?");
        emit UpdateDev(dev, dev_);
        dev = dev_;
    }

    // Update updater address.
    function setUpdater(address updater_) public {
        require(msg.sender == owner() || msg.sender == updater, "dev: wut?");
        emit UpdateUpdater(updater, updater_);
        updater = updater_;
    }
}