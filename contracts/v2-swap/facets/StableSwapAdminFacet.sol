pragma solidity ^0.8.10;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibStableSwap, StableSwapStorage, MAX_FEE, MAX_ADMIN_FEE, MIN_RAMP_TIME, MAX_A, MAX_A_CHANGE} from "../libraries/LibStableSwap.sol";
import {IERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/utils/SafeERC20.sol";

contract StableSwapAdminFacet {
    using SafeERC20 for IERC20;

    event CommitNewFee(
        uint256 indexed deadline,
        uint256 fee,
        uint256 admin_fee
    );
    event NewFee(uint256 fee, uint256 admin_fee);
    event RampA(
        uint256 old_A,
        uint256 new_A,
        uint256 initial_time,
        uint256 future_time
    );
    event StopRampA(uint256 A, uint256 t);
    event RevertParameters();
    event DonateAdminFees();
    event StableSwapPaused();
    event StableSwapUnpaused();
    // event Kill();
    // event Unkill();

    modifier onlyOwner() {
        require(LibDiamond.contractOwner() == msg.sender, "dev: only owner");
        _;
    }

    //////////////// VIEW FUNCTION

    function initial_A() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.initial_A;
    }

    function future_A() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.future_A;
    }

    function initial_A_time() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.initial_A_time;
    }

    function future_A_time() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.future_A_time;
    }

    function future_fee() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.future_fee;
    }


    function future_admin_fee() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.future_admin_fee;
    }

    function admin_actions_deadline() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.admin_actions_deadline;
    }

    function is_paused() external view returns (bool) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.paused;
    }

    // 
    function ramp_A(
        uint256 _future_A,
        uint256 _future_time
    ) external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(
            block.timestamp >= ss.initial_A_time + MIN_RAMP_TIME,
            "dev : too early"
        );
        require(
            _future_time >= block.timestamp + MIN_RAMP_TIME,
            "dev: insufficient time"
        );

        uint256 _initial_A = _get_A();
        require(
            _future_A > 0 && _future_A < MAX_A,
            "_future_A must be between 0 and MAX_A"
        );
        require(
            (_future_A >= _initial_A &&
                _future_A <= _initial_A * MAX_A_CHANGE) ||
                (_future_A < _initial_A &&
                    _future_A * MAX_A_CHANGE >= _initial_A),
            "Illegal parameter _future_A"
        );
        ss.initial_A = _initial_A;
        ss.future_A = _future_A;
        ss.initial_A_time = block.timestamp;
        ss.future_A_time = _future_time;

        emit RampA(_initial_A, _future_A, block.timestamp, _future_time);
    }

    function stop_ramp_get_A() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256 current_A = _get_A();
        ss.initial_A = current_A;
        ss.future_A = current_A;
        ss.initial_A_time = block.timestamp;
        ss.future_A_time = block.timestamp;
        // now (block.timestamp < t1) is always False, so we return saved A

        emit StopRampA(current_A, block.timestamp);
    }

    function commit_new_fee(
        uint256 new_fee,
        uint256 new_admin_fee
    ) external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(
            ss.admin_actions_deadline == 0,
            "admin_actions_deadline must be 0"
        ); // dev: active action
        require(new_fee <= MAX_FEE, "dev: fee exceeds maximum");
        require(
            new_admin_fee <= MAX_ADMIN_FEE,
            "dev: admin fee exceeds maximum"
        );

        // ss.admin_actions_deadline = block.timestamp + 1 days; // disable temp
        ss.future_fee = new_fee;
        ss.future_admin_fee = new_admin_fee;

        emit CommitNewFee(ss.admin_actions_deadline, new_fee, new_admin_fee);
    }

    function apply_new_fee() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        // require(
        //     block.timestamp >= ss.admin_actions_deadline,
        //     "dev: insufficient time"
        // ); // disable temp
        require(
            ss.admin_actions_deadline != 0,
            "admin_actions_deadline should not be 0"
        );

        ss.admin_actions_deadline = 0;
        ss.fee = ss.future_fee;
        ss.admin_fee = ss.future_admin_fee;

        emit NewFee(ss.fee, ss.admin_fee);
    }

    function revert_new_parameters() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        ss.admin_actions_deadline = 0;
        emit RevertParameters();
    }

    function admin_balances(uint256 i) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return IERC20(ss.coins[i]).balanceOf(address(this)) - ss.balances[i];
    }

    function withdraw_admin_fees() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        for (uint256 i = 0; i < 2; i++) {
            address c = ss.coins[i];
            uint256 value = IERC20(c).balanceOf(address(this)) - ss.balances[i];
            if (value > 0) {
                IERC20(c).safeTransfer(msg.sender, value);
            }
        }
    }

    function donate_admin_fees() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        for (uint256 i = 0; i < 2; i++) {
            ss.balances[i] = IERC20(ss.coins[i]).balanceOf(address(this));
        }
        emit DonateAdminFees();
    }

    function pause() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        ss.paused = true;
        emit StableSwapPaused();
    }

    function unpause() external onlyOwner {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        ss.paused = false;
        emit StableSwapUnpaused();
    }

    // INTERNAL FUNCTION

    function _get_A() internal view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256 t1 = ss.future_A_time;
        uint256 A1 = ss.future_A;
        if (block.timestamp < t1) {
            uint256 A0 = ss.initial_A;
            uint256 t0 = ss.initial_A_time;
            // Expressions in uint256 cannot have negative numbers, thus "if"
            if (A1 > A0) {
                return A0 + ((A1 - A0) * (block.timestamp - t0)) / (t1 - t0);
            } else {
                return A0 - ((A0 - A1) * (block.timestamp - t0)) / (t1 - t0);
            }
        } else {
            // when t1 == 0 or block.timestamp >= t1,
            // then it means the A parameter is already at its future value
            return A1;
        }
    }
}
