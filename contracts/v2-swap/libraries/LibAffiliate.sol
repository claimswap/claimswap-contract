pragma solidity ^0.8.10;

struct AffiliateStorage {
    uint256[] totalAffiliateFee; // total not claimed affiliate fee balance
    mapping(address => uint256) affiliateFee; // feeRate 
    mapping(address => uint256[]) affiliateBalance; // fee balance
}

library LibAffiliate {
    bytes32 constant AFFILIATE_STORAGE_POSITION = keccak256("claimswap.v2.lib.affiliate.storage");
    function diamondStorage() internal pure returns (AffiliateStorage storage ds) {
        bytes32 position = AFFILIATE_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}