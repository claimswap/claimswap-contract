// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/SafeCast.sol";
import "../codes/Ownable.sol";
import "../CLA/ClaimToken.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IClsToken.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/**
 * @title MasterChef of Fee.
 * distribute swap fee to CLS holders
 *
 * References:
 * - https://github.com/sushiswap/sushiswap/blob/canary/contracts/MasterChefV2.sol
 */
contract FeeDistributor is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user's rewardDebt.
    /// `rewardDebt` The amount of Fee entitled to the user.
    mapping(uint256 => mapping(address => int256)) public rewardDebt;

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
    PoolInfo[] public poolInfo;
    /// @notice Address of the fee token for each pool.
    IERC20[] public feeToken;
    /// @notice Mapping address => indexed
    mapping(address => uint256) private _tIdOf;

    mapping(address => bool) public feeLp;

    uint256 private constant ACC_FEE_PRECISION = 1e24;

    event Deposit(uint256 indexed tId, uint256 amount, address indexed to);
    event Withdraw(uint256 indexed tId, uint256 amount, address indexed to);
    event Harvest(
        address indexed user,
        uint256 indexed tId,
        uint256 amount,
        address indexed to
    );
    event AddToken(uint256 indexed tId, IERC20 indexed feeToken);
    event RemoveToken(uint256 indexed tId, IERC20 indexed feeToken);
    event AddLp(IUniswapV2Pair indexed feeLp);
    event RemoveLp(IUniswapV2Pair indexed feeLp);
    event UpdatePool(
        uint256 indexed tId,
        uint256 clsSupply,
        uint256 accFeePerShare
    );
    event UpdateDev(address prevDev, address newDev);
    event UpdateUpdater(address prevUpdater, address newUpdater);


    constructor(
        address cla_,
        address cls_,
        address dev_,
        IUniswapV2Router02 router_
    ) public {
        cla = cla_;
        cls = cls_;
        dev = dev_;
        emit UpdateDev(address(0), dev_);
        router = router_;
    }

    /// @notice Returns the number of fee distributor pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new fee token to the pool. Can only be called by the owner.
    /// @param feeToken_ Address of the ERC-20 token.
    function addToken(IERC20 feeToken_) public onlyOwner {
        require(feeToken.length == 0 || (_tIdOf[address(feeToken_)] == 0 && feeToken[0] != feeToken_), "feeToken_ already exists");
        _tIdOf[address(feeToken_)] = feeToken.length;
        feeToken.push(feeToken_);

        poolInfo.push(PoolInfo({accFeePerShare: 0}));
        emit AddToken(feeToken.length.sub(1), feeToken_);
    }

    /// @notice Remove a fee token from the pool. Can only be called by the owner.
    /// @param feeToken_ Address of the ERC-20 token.
    function removeToken(IERC20 feeToken_) public onlyOwner {
        require(_tIdOf[address(feeToken_)] != 0 || feeToken[0] == feeToken_, "feeToken_ does not exist");
        delete _tIdOf[address(feeToken_)];
        emit RemoveToken(_tIdOf[address(feeToken_)], feeToken_);
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
    /// @param tId The index of the pool. See `poolInfo`.
    /// @param user Address of user.
    /// @return Pending fee reward for a given user.
    function pendingFee(uint256 tId, address user)
        external
        view
        returns (uint256 pending)
    {
        pending = int256(
            IERC20(cls).balanceOf(user).mul(poolInfo[tId].accFeePerShare) /
                ACC_FEE_PRECISION
        ).sub(rewardDebt[tId][user]).toUint256();
        pending = pending.sub(pending / 2);
    }

    /// @notice Update reward variables of the given LP.
    /// @param feeLps List of LP to update.
    /// @param amount0Mins List of minimum amount of token0.
    /// @param amount1Mins List of minimum amount of token1.
    function updatePools(IUniswapV2Pair[] memory feeLps, uint256[] memory amount0Mins, uint256[] memory amount1Mins) public {
        require(msg.sender == owner() || msg.sender == updater, "Invalid access");
        uint256 len = feeLps.length;
        for (uint256 i = 0; i < len; ++i) {
            IUniswapV2Pair feeLp_ = feeLps[i];
            uint256 amount = feeLp_.balanceOf(address(this));
            if(amount > 0) {
                if (feeLp[address(feeLps[i])] == true) {
                    address token0 = feeLp_.token0();
                    address token1 = feeLp_.token1();
                    IERC20(address(feeLp_)).safeApprove(address(router), amount);
                    (uint256 amountA, uint256 amountB) = router.removeLiquidity(
                                token0,
                                token1,
                                amount,
                                amount0Mins[i],
                                amount1Mins[i],
                                address(this),
                                block.timestamp
                            );
                    // amountA and amountB is always higher than 0
                    _updatePool(token0, amountA);
                    _updatePool(token1, amountB);
                }
                else{
                    IERC20(address(feeLp_)).safeTransfer(dev, amount);
                }
            }
        }
    }

    /// @notice Update reward variables of the given fee token.
    /// @param feeToken_ addres of fee token.
    /// @param amount amount of fee.
    function updateFeeToken(address feeToken_, uint256 amount) public {
        require(msg.sender == owner() || msg.sender == updater, "Invalid access");
        uint256 tId = _tIdOf[feeToken_];
        uint256 totalSupply = IERC20(cls).totalSupply();
        if (
            (tId > 0 || address(feeToken[0]) == feeToken_) &&
            totalSupply > 0
        ) {
            IERC20(feeToken_).safeTransferFrom(msg.sender, address(this), amount);
            poolInfo[tId].accFeePerShare = poolInfo[tId].accFeePerShare.add(
                amount.mul(ACC_FEE_PRECISION) / totalSupply
            );
            emit UpdatePool(
                tId,
                totalSupply,
                poolInfo[tId].accFeePerShare
            );
        } else {
            IERC20(feeToken_).safeTransferFrom(msg.sender, dev, amount);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param feeToken_ addres of fee token.
    /// @param amount amount of fee.
    function _updatePool(address feeToken_, uint256 amount) internal {
        uint256 tId = _tIdOf[feeToken_];
        uint256 totalSupply = IERC20(cls).totalSupply();
        if (
            (tId > 0 || address(feeToken[0]) == feeToken_) &&
            totalSupply > 0
        ) {
            poolInfo[tId].accFeePerShare = poolInfo[tId].accFeePerShare.add(
                amount.mul(ACC_FEE_PRECISION) / totalSupply
            );
            emit UpdatePool(
                tId,
                totalSupply,
                poolInfo[tId].accFeePerShare
            );
        } else {
            IERC20(feeToken_).safeTransfer(dev, amount);
        }
    }

    /// @notice Deposit CLS tokens for rewards allocation.
    /// @param tId The index of the pool. See `poolInfo`.
    /// @param amount CLS token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function _deposit(
        uint256 tId,
        uint256 amount,
        address to
    ) internal {
        rewardDebt[tId][to] = rewardDebt[tId][to].add(
            int256(amount.mul(poolInfo[tId].accFeePerShare) / ACC_FEE_PRECISION)
        );

        emit Deposit(tId, amount, to);
    }

    /// @notice Withdraw CLS tokens.
    /// @param tId The index of the pool. See `poolInfo`.
    /// @param amount CLS token amount to withdraw.
    /// @param to Receiver of the CLS tokens.
    function _withdraw(
        uint256 tId,
        uint256 amount,
        address to
    ) internal {
        rewardDebt[tId][to] = rewardDebt[tId][to].sub(
            int256(amount.mul(poolInfo[tId].accFeePerShare) / ACC_FEE_PRECISION)
        );
        emit Withdraw(tId, amount, to);
    }

    /// @notice Automatically call `deposit` when CLS is minted.
    function deposit(address user, uint256 amount) public {
        require(msg.sender == cls);
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            _deposit(i, amount, user);
        }
    }

    /// @notice Automatically call `withdraw` when CLS is burned.
    function withdraw(address user, uint256 amount) public {
        require(msg.sender == cls);
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            _withdraw(i, amount, user);
        }
    }

    /// @dev Harvest all proceeds for transaction sender to `to`.
    /// @param to Receiver of rewards.
    /// @param boost If true, all rewards are converted to CLA.
    /// @param paths The list of paths to CLA
    /// @param minAmounts The list of minimum amount of CLA when swapped.
    function harvestAll(
        address to,
        bool boost,
        address[][] calldata paths,
        uint256[] calldata minAmounts
    ) external {
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            harvest(i, to, boost, paths[i], minAmounts[i]);
        }
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param tId The index of the pool. See `poolInfo`.
    /// @param to Receiver of fee rewards.
    /// @param boost If true, all rewards are converted to CLA.
    /// @param path The path from fee token to CLA.
    function harvest(
        uint256 tId,
        address to,
        bool boost,
        address[] memory path,
        uint256 minAmount
    ) public {
        PoolInfo memory pool = poolInfo[tId];
        int256 accumulatedFee = int256(
            IERC20(cls).balanceOf(msg.sender).mul(pool.accFeePerShare) /
                ACC_FEE_PRECISION
        );
        uint256 _pendingFee = accumulatedFee
            .sub(rewardDebt[tId][msg.sender])
            .toUint256();

        rewardDebt[tId][msg.sender] = accumulatedFee;

        if (_pendingFee != 0) {
            if (!boost) {
                uint256 noClaFee = _pendingFee / 2;
                _pendingFee = _pendingFee.sub(noClaFee);

                safeFeeTokenTransfer(tId, dev, noClaFee);
                safeFeeTokenTransfer(tId, to, _pendingFee);
            } else {
                uint256 amountCla = _pendingFee;
                // cla-boost
                if (tId != 0) {
                    //not Claim Token
                    require(
                        path[path.length - 1] == cla,
                        "Invalid path"
                    );
                    feeToken[tId].safeApprove(address(router),_pendingFee);
                    uint256[] memory amounts = router.swapExactTokensForTokens(
                        _pendingFee,
                        minAmount,
                        path,
                        address(this),
                        uint256(-1)
                    );
                    amountCla = amounts[amounts.length - 1];
                }
                IERC20(cla).safeApprove(cls, amountCla);
                IClsToken(cls).mintClaimBoost(to, amountCla);
            }
        }

        emit Harvest(msg.sender, tId, _pendingFee, to);
    }

    // Safe token transfer function, just in case if rounding error causes pool to not have enough tokens.
    function safeFeeTokenTransfer(
        uint256 tId,
        address to,
        uint256 amount
    ) internal {
        uint256 bal = feeToken[tId].balanceOf(address(this));
        if (amount > bal) {
            feeToken[tId].safeTransfer(to, bal);
        } else {
            feeToken[tId].safeTransfer(to, amount);
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