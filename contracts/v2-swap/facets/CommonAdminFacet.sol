pragma solidity ^0.8.10;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import { IERC173 } from "../interfaces/IERC173.sol";

contract CommonAdminFacet is IERC173 {

    event TransferPaused();
    event TransferUnpaused();
    event MigratorChanged(address newMigrator);

    function setFactory(address _factory) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.diamondStorage().factory = _factory;
    }

    function setSwapType(uint256 _swapType) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.diamondStorage().swapType = _swapType;
    }

    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    function owner() external override view returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    function setTransferPaused() external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.diamondStorage().transferPaused = true;
        emit TransferPaused();
    }

    function setTransferUnpaused() external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.diamondStorage().transferPaused = false;
        emit TransferUnpaused();
    }

    function setMigrator(address newMigrator) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.diamondStorage().migrator = newMigrator;
        emit MigratorChanged(newMigrator);
    }
}