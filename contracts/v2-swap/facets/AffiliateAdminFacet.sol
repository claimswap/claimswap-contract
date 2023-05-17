pragma solidity ^0.8.10;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibAffiliate, AffiliateStorage} from "../libraries/LibAffiliate.sol";

contract AffiliateAdminFacet {

    event NewAffiliateAddressAdded(address indexed affiliateAddr);
    
    modifier onlyOwner() {
        require(LibDiamond.contractOwner() == msg.sender, "dev: only owner");
        _;
    }
    
    function initializeAffiliate(address _affiliate, uint256 _feeRate) external onlyOwner  {
        AffiliateStorage storage afs = LibAffiliate.diamondStorage();
        afs.affiliateFee[_affiliate] = _feeRate;
        afs.affiliateBalance[_affiliate] = new uint256[](afs.totalAffiliateFee.length);
        emit NewAffiliateAddressAdded(_affiliate);
    }
}