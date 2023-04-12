pragma solidity ^0.8.10;

import {LibAppStorage, AppStorage} from "./LibAppStorage.sol";

uint256 constant MAX_DECIMAL = 18;
uint256 constant FEE_DENOMINATOR = 1e10;
uint256 constant PRECISION = 1e18;

uint256 constant MAX_ADMIN_FEE = 1e10;
uint256 constant MAX_FEE = 5e9;
uint256 constant MAX_A = 1e6;
uint256 constant MAX_A_CHANGE = 10;

uint256 constant MIN_RAMP_TIME = 1 days;

struct StableSwapStorage {
    uint256[] PRECISION_MUL;
    uint256[] RATES;
    
    address[] coins;
    uint256[] balances;
    uint256 fee;
    uint256 admin_fee;

    uint256 initial_A;
    uint256 future_A;
    uint256 initial_A_time;
    uint256 future_A_time;

    uint256 admin_actions_deadline;
    uint256 future_fee;
    uint256 future_admin_fee;

    bool paused;
}

library LibStableSwap {
    bytes32 constant STABLE_SWAP_STORAGE_POSITION = keccak256("claimswap.v2.lib.stableswap.storage");
    function diamondStorage() internal pure returns (StableSwapStorage storage ds) {
        bytes32 position = STABLE_SWAP_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}