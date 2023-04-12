pragma solidity ^0.8.10;

library LibAppStorage {
    function diamondStorage() internal pure returns (AppStorage storage ds) {
        assembly {
            ds.slot := 0
        }
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}

struct AppStorage {
    // ERC20
    mapping(address => uint256) balances;
    mapping(address => mapping(address => uint256)) allowances;
    uint256 totalSupply;

    // ERC20 Metadata
    string name;
    string symbol;
    uint8 decimals;

    uint256 swapType;
    address factory;
    address migrator;

    bool isInitialized;
    bool transferPaused;
}
