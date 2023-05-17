pragma solidity ^0.8.10;

import {LibAffiliate, AffiliateStorage} from "../libraries/LibAffiliate.sol";
import {LibStableSwap, StableSwapStorage} from "../libraries/LibStableSwap.sol";
import {IERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/utils/SafeERC20.sol";

contract AffiliateFacet {
    using SafeERC20 for IERC20;

    event AffiliateFeeClaimed(address indexed affiliateAddr, uint256 indexed i, uint256 indexed amount);

    // Check affiliate balance
    function affiliateFeeBalances(address _affiliate, uint256 i) external view returns (uint256) {
        AffiliateStorage storage afs = LibAffiliate.diamondStorage();
        return afs.affiliateBalance[_affiliate][i];
    }

    // Claim Fee
    function claimAffiliateFee(uint256 i) external returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        AffiliateStorage storage afs = LibAffiliate.diamondStorage();
        address c = ss.coins[i];
        uint256 value = afs.affiliateBalance[msg.sender][i];
        afs.affiliateBalance[msg.sender][i] = 0;
        afs.totalAffiliateFee[i] -= value;
        if (value > 0) {
            IERC20(c).safeTransfer(msg.sender, value);
            emit AffiliateFeeClaimed(msg.sender, i, value);
        }
        return value;
    }
}