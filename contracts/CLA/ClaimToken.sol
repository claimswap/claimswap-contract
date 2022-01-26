// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;

import '../codes/ERC20.sol';
import '../codes/Ownable.sol';

interface ITreasury {
    function setCla(address) external;
}

/**
 * @title CLA token.
 * No delegation thru signing.
 *
 * References:
 *
 * - https://github.com/sushiswap/sushiswap/blob/master/contracts/SushiToken.sol
 */
contract ClaimToken is ERC20('ClaimSwap', 'CLA'), Ownable {
    /// @notice Total token amounts.
    uint256 private constant TOTAL_TOKEN_AMOUNT = 186624000e18;
    uint256 private constant MINING_TOKEN_AMOUNT =
        (TOTAL_TOKEN_AMOUNT / 10) * 6; //111974400e18;

    bool public paused;

    /**
     * @dev Emitted when the pause is triggered by owner
     */
    event Paused();

    /**
     * @dev Emitted when the pause is lifted by owner.
     */
    event Unpaused();

    /// @notice Creates `TOTAL_AMOUNT` token to `_treasury`.
    /// Must only be called by the owner (MasterChef).
    constructor(ITreasury miningTreasury, ITreasury treasury) public {
        treasury.setCla(address(this));
        miningTreasury.setCla(address(this));
        _mint(address(miningTreasury), MINING_TOKEN_AMOUNT);
        _mint(address(treasury), TOTAL_TOKEN_AMOUNT - MINING_TOKEN_AMOUNT);
    }
    
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal { 
        super._beforeTokenTransfer(from, to, amount);

        require(!paused, 'paused');
    }
  
    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function pause() public onlyOwner {
        require(!paused, 'already paused');
        paused = true;
        emit Paused();
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function unpause() public onlyOwner {
        require(paused, 'already unpaused');
        paused = false;
        emit Unpaused();
    }
}