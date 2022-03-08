pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../codes/Ownable.sol";

interface IFeeDistributorV2 {
    function updatePool(
        IUniswapV2Pair feeLp_,
        uint256 token0Min,
        uint256 token1Min,
        uint256 cla0Min,
        uint256 cla1Min,
        address[] calldata path0,
        address[] calldata path1
    ) external;
}

contract FeeDistributorUpdaterV2 is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IFeeDistributorV2 public feeDistributorV2;
    mapping(address => uint256) public lastExecuteTime;
    uint256 public interval = 1 days;

    constructor(IFeeDistributorV2 feeDistributorV2_) public {
        feeDistributorV2 = feeDistributorV2_;
    }

    // EVENTS
    event UpdateInterval(uint256 prevInterval, uint256 newInterval);
    event UpdateOffset(uint256 prevOffset, uint256 newOffset);
    event ExecuteUpdatePool(address indexed feeLp_, uint256 excuteTime);

    /// @notice update interval of execute update pool
    /// @param newInterval seconds of interval
    function updateInterval(uint256 newInterval) public onlyOwner {
        emit UpdateInterval(interval, newInterval);
        interval = newInterval;
    }

    /// @notice excute fee distributor update pool function
    function executeUpdatePool(
        IUniswapV2Pair feeLp_,
        uint256 token0Min,
        uint256 token1Min,
        uint256 cla0Min,
        uint256 cla1Min,
        address[] memory path0,
        address[] memory path1
    ) public onlyOwner {
        IFeeDistributorV2(feeDistributorV2)
            .updatePool(
                feeLp_,
                token0Min,
                token1Min,
                cla0Min,
                cla1Min,
                path0,
                path1
            );
        lastExecuteTime[address(feeLp_)] = block.timestamp;
        emit ExecuteUpdatePool(address(feeLp_), block.timestamp);
    }
}
