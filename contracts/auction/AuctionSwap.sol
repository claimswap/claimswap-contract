pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../libraries/BoringMath.sol";
import "../codes/Ownable.sol";

/**
 * @title CLA Token Batch Auction Contract
 * References:
 *
 * - https://github.com/sushiswap/miso/blob/master/contracts/Auctions/BatchAuction.sol
 */
contract AuctionSwap is ReentrancyGuard, Ownable {
    using BoringMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Main market variables.
    struct MarketInfo {
        uint256 startTime;
        uint256 endTime;
        uint256 claimableTime;
        uint256 totalTokens;
    }
    MarketInfo public marketInfo;

    /// @notice Market dynamic variables.
    struct MarketStatus {
        uint256 commitmentsTotal;
        uint256 minimumCommitmentAmount;
        uint256 maximumCommitmentAmount;
        bool finalized;
        bool emergencyCanceled; /// @dev true if auction canceled during auction is ongoing. 
        bool paused; /// @dev flag that auction is paused 
    }
    MarketStatus public marketStatus;

    /// @notice Auction User variables.
    struct UserInfo {
        uint256 commitment; /// @dev user klay commitment
        uint256 claimed; /// @dev user auction token claimed amount
    }
    mapping(address => UserInfo) public userInfo; /// @dev address => UserInfo

    /// @dev address of sales token
    address public auctionToken;
    /// @dev where the auction funds will get paid
    address payable public wallet;
    /// @dev The placeholder KLAY address.
    address private constant KLAY_ADDRESS =
        0x0000000000000000000000000000000000000000;

    /// @notice boolean flag that auction swap information is initalized
    /// @dev this contract can be used once
    bool private isInitalized;

    /// @dev token vesting perionds in seconds
    uint256 private constant TOKEN_VESTING_DURATION = 45 days;

    /// @notice Event for updating auction times.  Needs to be before auction starts.
    event AuctionTimeUpdated(uint256 startTime, uint256 endTime);
    /// @notice Event for updating auction prices. Needs to be before auction starts.
    event AuctionMinimumPriceUpdated(uint256 minimumCommitmentAmount);
    /// @notice Event for updating auction prices. Needs to be before auction starts.
    event AuctionMaximumPriceUpdated(uint256 maximumCommitmentAmount);
    /// @notice Event for updating auction wallet. Needs to be before auction starts.
    event AuctionWalletUpdated(address wallet);
    /// @notice Event for adding a commitment.
    event AddedCommitment(address addr, uint256 commitment);
    /// @notice Event for finalization of the auction.
    event AuctionFinalized();
    /// @notice Event for cancellation of the auction.
    event AuctionCancelled();
    /// @notice Event for cancellation during the auction.
    event AuctionEmergencyCancelled();
    /// @notice Event for pause of the auction.
    event AuctionPaused();
    /// @notice Event for resume of the auction.
    event AuctionResume(uint256 endTime);
    /// @notice Event for update claimable time.
    event AuctionClaimableTimeChanged(uint256 before_, uint256 after_);

    /**
     * @notice Initializes main contract variables and transfers funds for the auction.
     * @dev Init function.
     * @param funder The address that funds the token for BatchAuction.
     * @param token Address of the token being sold.
     * @param totalTokens The total number of tokens to sell in auction.
     * @param startTime Auction start time.
     * @param endTime Auction end time.
     * @param claimableTime Token claimable time if auction success.
     * @param minimumCommitmentAmount Minimum amount collected at which the auction will be successful.
     * @param maximumCommitmentAmount Maximum amount collected at which the auction will be successful.
     * @param wallet_ Address where collected funds will be forwarded to.
     */
    function initAuction(
        address funder,
        address token,
        uint256 totalTokens,
        uint256 startTime,
        uint256 endTime,
        uint256 claimableTime,
        uint256 minimumCommitmentAmount,
        uint256 maximumCommitmentAmount,
        address payable wallet_
    ) public onlyOwner {
        require(!isInitalized, "AuctionSwap: alreay initialized");
        require(
            claimableTime < 10000000000,
            "AuctionSwap: enter an unix timestamp in seconds, not miliseconds"
        );
        require(
            startTime >= block.timestamp,
            "AuctionSwap: start time is before current time"
        );
        require(
            endTime > startTime,
            "AuctionSwap: end time must be older than start time"
        );
        require(
            claimableTime > endTime, 
            "AuctionSwap: claimable time must be older than auction end time"
        );
        require(
            totalTokens > 0,
            "AuctionSwap: total tokens must be greater than zero"
        );
        require(
            wallet_ != address(0),
            "AuctionSwap: wallet is the zero address"
        );
        require(
            minimumCommitmentAmount < maximumCommitmentAmount,
            "AuctionSwap: min max commitment amount error"
        );
        isInitalized = true;

        marketStatus.minimumCommitmentAmount = minimumCommitmentAmount;
        marketStatus.maximumCommitmentAmount = maximumCommitmentAmount;

        marketInfo.startTime = startTime;
        marketInfo.endTime = endTime;
        marketInfo.claimableTime = claimableTime;
        marketInfo.totalTokens = totalTokens;

        auctionToken = token;
        wallet = wallet_;

        IERC20(auctionToken).safeTransferFrom(funder, address(this), totalTokens);
    }

    ///--------------------------------------------------------
    /// Commit to buying tokens!
    ///--------------------------------------------------------


    /**
     * @notice Commit KLAY to buy tokens on auction.
     * @param beneficiary Auction participant KLAY address.
     */
    function commitKLAY(
        address beneficiary
    ) public payable nonReentrant {
        require(msg.value > 0, "AuctionSwap: Value must be higher than 0");
        require(!marketStatus.finalized, "AuctionSwap: Auction finalized");

        _addCommitment(beneficiary, msg.value);

        /// @notice Revert if commitmentsTotal exceeds the balance
        require(
            marketStatus.commitmentsTotal <= address(this).balance,
            "AuctionSwap: The committed KLAY exceeds the balance"
        );
        require(
            marketStatus.maximumCommitmentAmount >=
                marketStatus.commitmentsTotal,
            "AuctionSwap: The committed KLAY exceeds maximumCommitmentAmount"
        );
    }

    /// @notice Commits to an amount during an auction
    /**
     * @notice Updates commitment for this address and total commitment of the auction.
     * @param addr Auction participant address.
     * @param commitment The amount to commit.
     */
    function _addCommitment(address addr, uint256 commitment) internal {
        require(
            block.timestamp >= marketInfo.startTime &&
                block.timestamp <= marketInfo.endTime,
            "AuctionSwap: Outside auction hours"
        );
        require(!marketStatus.paused, "AuctionSwap: Auction paused!");
        UserInfo storage user = userInfo[addr];

        user.commitment = user.commitment.add(commitment);
        marketStatus.commitmentsTotal = marketStatus.commitmentsTotal.add(commitment);
        emit AddedCommitment(addr, commitment);
    }

    /**`
     * @notice Calculates amount of auction tokens for user to receive.
     * @param amount Amount of tokens to commit.
     * @return Auction token amount.
     */
    function _getTokenAmount(uint256 amount) internal view returns (uint256) {
        if (marketStatus.commitmentsTotal == 0) return 0;
        return amount.mul(1e18).div(tokenPrice());
    }

    /**
     * @notice Calculates the price of each token from all commitments.
     * @return Token price.
     */
    function tokenPrice() public view returns (uint256) {
        return marketStatus.commitmentsTotal.mul(1e18).div(marketInfo.totalTokens);
    }

    ///--------------------------------------------------------
    /// Finalize, Stop, Resume Auction
    ///--------------------------------------------------------

    /// @notice Auction finishes successfully above the reserve
    /// @dev Transfer contract funds to initialized wallet.
    function finalize() public nonReentrant onlyOwner {
        require(
            !marketStatus.finalized,
            "AuctionSwap: Auction has already finalized"
        );
        require(isInitalized, "AuctionSwap: Not initialized");
        require(
            block.timestamp > marketInfo.endTime,
            "AuctionSwap: Auction has not finished yet"
        );
        marketStatus.finalized = true;
        if (auctionSuccessful()) {
            /// @dev Successful auction
            /// @dev Transfer KLAY to wallet.
            _safeTransferKLAY(
                wallet,
                marketStatus.commitmentsTotal
            );
        } else {
            /// @dev Failed auction
            /// @dev Return auction tokens back to wallet.
            IERC20(auctionToken).safeTransfer(wallet, marketInfo.totalTokens);
        }
        emit AuctionFinalized();
    }

    /**
     * @notice Cancel Auction before start
     * @dev Admin can cancel the auction before it starts
     */
    function cancelAuction() public onlyOwner {
        require(!marketStatus.finalized, "AuctionSwap: Already finalized");
        require(isInitalized, "AuctionSwap: Not initialized");
        require(
            marketStatus.commitmentsTotal == 0,
            "AuctionSwap: Funds already raised"
        );
        marketStatus.finalized = true;
        IERC20(auctionToken).safeTransfer(wallet, marketInfo.totalTokens);
        emit AuctionCancelled();
    }

    /**
     * @notice Cancel Auction during auction.
     * @dev emergency only. admin function
     */
    function emergencyCancelAuction() public onlyOwner {
        require(!marketStatus.finalized, "AuctionSwap: Already finalized");
        require(isInitalized, "AuctionSwap: Not initialized");
        marketStatus.finalized = true;
        marketStatus.emergencyCanceled = true;
        IERC20(auctionToken).safeTransfer(wallet, marketInfo.totalTokens);
        emit AuctionEmergencyCancelled();
    }

    /**
     * @notice pause auction during auction.
     * @dev Admin can pause auction during auction. 
     */
    function pauseAuction() public onlyOwner {
        require(!marketStatus.paused, "AuctionSwap: Already paused");
        require(!marketStatus.finalized, "AuctionSwap: Already finalized");
        require(block.timestamp > marketInfo.startTime && block.timestamp < marketInfo.endTime, "AuctionSwap: Outside auction hours");
        marketStatus.paused = true;
        emit AuctionPaused();
    }

    /**
     * @notice resume auction during auction and can extend end time
     * @dev Admin can resume auction and can extend end time 
     */
    function resumeAuction(uint256 endTime) public onlyOwner {
        require(marketStatus.paused, "AuctionSwap: Alreay resumed");
        require(!marketStatus.finalized, "AuctionSwap: Already finalized");
        require(block.timestamp > marketInfo.startTime && block.timestamp < marketInfo.endTime, "AuctionSwap: Outside auction hours");
        require(
            endTime < 10000000000,
            "AuctionSwap: Enter an unix timestamp in seconds, not miliseconds"
        );
        marketStatus.paused = false;
        if (marketInfo.endTime < endTime) { // endtime과 claimable time도 비교해야하는가?
            marketInfo.endTime = endTime;
        }
        emit AuctionResume(marketInfo.endTime);
    }

    /// @notice Withdraws bought tokens, or returns commitment if the sale is unsuccessful.
    function withdrawTokens() public {
        withdrawTokens(msg.sender);
    }

    /// @notice Withdraw your tokens once the Auction has ended.
    function withdrawTokens(address payable beneficiary) public nonReentrant {
        /// @dev auction success and auction not canceled
        UserInfo storage user = userInfo[beneficiary];
        if (auctionSuccessful() && !marketStatus.emergencyCanceled) {
            require(marketStatus.finalized, "AuctionSwap: Not finalized");
            require(block.timestamp > marketInfo.claimableTime, "AuctionSwap: Not claimable");
            /// @dev Successful auction! Transfer claimed tokens.
            uint256 tokensToClaim = tokensClaimable(beneficiary);
            require(tokensToClaim > 0, "AuctionSwap: No tokens to claim");
            user.claimed = user.claimed.add(tokensToClaim);
            IERC20(auctionToken).safeTransfer(beneficiary, tokensToClaim);
        } else {
            /// @dev Auction did not meet reserve price or emergency canceled
            /// @dev Return committed funds back to user.
            require(
                block.timestamp > marketInfo.endTime || marketStatus.emergencyCanceled,
                "AuctionSwap: Auction has not finished yet"
            );
            uint256 fundsCommitted = user.commitment;
            require(fundsCommitted > 0, "AuctionSwap: No funds committed");
            user.commitment = 0; // Stop multiple withdrawals and free some gas
            _safeTransferKLAY(beneficiary, fundsCommitted);
        }
    }

    /**
     * @notice How many tokens that user is able to claim if total amount is given
     * @param totalAmount total token amount
     */
    function tokensVested(uint256 totalAmount) public view returns (uint256) {
        if (block.timestamp <= marketInfo.claimableTime) {
            return 0;
        } else if (block.timestamp >= marketInfo.claimableTime.add(TOKEN_VESTING_DURATION)) {
            return totalAmount;
        } else {
            return totalAmount.mul(block.timestamp.sub(marketInfo.claimableTime)) / TOKEN_VESTING_DURATION;
        }
    }

    /**
     * @notice How many tokens the user is able to claim.
     * @param user_ Auction participant address.
     * @return  claimerCommitment Tokens left to claim.
     */
    function tokensClaimable(address user_)
        public
        view
        returns (uint256 claimerCommitment)
    {
        UserInfo storage user = userInfo[user_];
        if (user.commitment == 0) return 0;
        uint256 unclaimedTokens = IERC20(auctionToken).balanceOf(address(this));  
        claimerCommitment = _getTokenAmount(user.commitment); /// @dev total user token swaped amount
        claimerCommitment = tokensVested(claimerCommitment); /// @dev vested amount
        if (claimerCommitment > user.claimed) {
            claimerCommitment = claimerCommitment.sub(user.claimed);  ///@dev claimable amount
        } else {
            claimerCommitment = 0;
        }

        if (claimerCommitment > unclaimedTokens) {
            claimerCommitment = unclaimedTokens;
        }
    }

    /**
     * @notice Checks if raised more than minimum amount.
     * @return True if tokens sold greater than or equals to the minimum commitment amount.
     */
    function auctionSuccessful() public view returns (bool) {
        return
            marketStatus.commitmentsTotal >= marketStatus.minimumCommitmentAmount && marketStatus.commitmentsTotal > 0;
    }

    /**
     * @notice Checks if the auction has ended.
     * @return bool True if current time is greater than auction end time.
     */
    function auctionEnded() public view returns (bool) {
        return block.timestamp > marketInfo.endTime;
    }

    /**
     * @notice Checks if the auction has been finalised.
     * @return bool True if auction has been finalised.
     */
    function finalized() public view returns (bool) {
        return marketStatus.finalized;
    }

    //--------------------------------------------------------
    // Setter Functions
    //--------------------------------------------------------

    /**
     * @notice Admin can set start and end time through this function.
     * @param startTime Auction start time.
     * @param endTime Auction end time.
     */
    function setAuctionTime(uint256 startTime, uint256 endTime)
        external
        onlyOwner
    {
        require(
            startTime < 10000000000,
            "AuctionSwap: enter an unix timestamp in seconds, not miliseconds"
        );
        require(
            endTime < 10000000000,
            "AuctionSwap: enter an unix timestamp in seconds, not miliseconds"
        );
        require(
            startTime >= block.timestamp,
            "AuctionSwap: start time is before current time"
        );
        require(
            endTime > startTime,
            "AuctionSwap: end time must be older than start price"
        );
        require(
            marketInfo.claimableTime > endTime, 
            "AuctionSwap: claimable time must be older than auction end time"
        );
        require(
            marketStatus.commitmentsTotal == 0,
            "AuctionSwap: auction cannot have already started"
        );
        
        marketInfo.startTime = startTime;
        marketInfo.endTime = endTime;
        emit AuctionTimeUpdated(marketInfo.startTime, marketInfo.endTime);
    }

    /**
     * @notice Admin can change cla claimable time through this function
     * @param claimableTime timestamp in second
     */
    function setClaimableTime(uint256 claimableTime) external onlyOwner {
        require(
            claimableTime < 10000000000,
            "AuctionSwap: enter an unix timestamp in seconds, not miliseconds"
        );
        require(
            claimableTime > marketInfo.endTime, 
            "AuctionSwap: claimable time must be older than auction end time"
        );
        require(
            claimableTime > block.timestamp, 
            "AuctionSwap: claimable time must be older than current time"
        );
        require(
            marketInfo.claimableTime > block.timestamp,
            "AuctionSwap: Already claim start"
        );
        emit AuctionClaimableTimeChanged(marketInfo.claimableTime, claimableTime);
        marketInfo.claimableTime = claimableTime;
    }

    /**
     * @notice Admin can set start and min price through this function.
     * @param minimumCommitmentAmount Auction minimum raised target.
     */
    function setAuctionMinPrice(uint256 minimumCommitmentAmount)
        external
        onlyOwner
    {
        require(
            marketStatus.commitmentsTotal == 0,
            "AuctionSwap: auction cannot have already started"
        );
        require(
            minimumCommitmentAmount < marketStatus.maximumCommitmentAmount, "AuctionSwap: min max commitment amount error"
        );
        marketStatus.minimumCommitmentAmount = minimumCommitmentAmount;
        emit AuctionMinimumPriceUpdated(marketStatus.minimumCommitmentAmount);
    }

    /**
     * @notice Admin can set start and min price through this function.
     * @param maximumCommitmentAmount Auction maximum raised target.
     */
    function setAuctionMaxPrice(uint256 maximumCommitmentAmount)
        external
        onlyOwner
    {
        require(
            marketStatus.commitmentsTotal == 0,
            "AuctionSwap: auction cannot have already started"
        );

        require(
            marketStatus.minimumCommitmentAmount < maximumCommitmentAmount, "AuctionSwap: min max commitment amount error"
        );
        marketStatus.maximumCommitmentAmount = maximumCommitmentAmount;
        emit AuctionMaximumPriceUpdated(marketStatus.maximumCommitmentAmount);
    }

    /**
     * @notice Admin can set the auction wallet through this function.
     * @param wallet_ Auction wallet is where funds will be sent.
     */
    function setAuctionWallet(address payable wallet_) external onlyOwner {
        require(
            wallet_ != address(0),
            "AuctionSwap: wallet is the zero address"
        );
        wallet = wallet_;

        emit AuctionWalletUpdated(wallet_);
    }

    /**
     * @notice send KLAY through this internal function
     * @param to receiver payable address
     * @param value amount of klay
     */
    function _safeTransferKLAY(address payable to, uint value) internal {
        bool success = to.send(value);
        require(success, 'AuctionSwap: KLAY_TRANSFER_FAILED');
    }
}
