pragma solidity ^0.8.10;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";

contract CommonFacet {
    
    function getSwapType() external view returns (uint256) {
        return LibAppStorage.diamondStorage().swapType;
    }

    function getFactory() external view returns (address) {
        return LibAppStorage.diamondStorage().factory;
    }
}