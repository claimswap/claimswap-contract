// SPDX-License-Identifier: MIT

pragma solidity ^0.5.13;
pragma experimental ABIEncoderV2;

import "../codes/ERC20Upgradeable.sol";
import "../codes/OwnableUpgradeable.sol";
import "../libraries/SafeERC20.sol";
import "../libraries/SafeCast.sol";
import "../libraries/BoringMath.sol";
import "../proxy/Initializable.sol";

interface IFeeDistributor {
    function deposit(address user, uint256 amount) external;

    function withdraw(address user, uint256 amount) external;
}

interface IClaDistributor {
    function deposit(address user, uint256 amount) external;

    function withdraw(address user, uint256 amount) external;
}

/**
 * @title CLS token.
 * No delegation thru signing.
 *
 * A wallet that holds CLS, but is undelegated cannot vote.
 * Even if you’re planning to vote yourself, you still need to manually delegate or “self-delegate”
 * to make those votes count.
 *
 * If Alice has 10 COMP and delegates her votes to Bob,
 * Bob now has 10 votes but cannot delegate those votes to Charles.
 * You can only delegate votes if you hold the corresponding CLS for those votes.
 *
 * If Alice is delegating to Bob and has 10 COMP in her wallet, Bob has 10 votes.
 * If Charles sends Alice 10 more COMP, Alice now has 20 COMP
 * and her delegation to Bob is automatically updated to 20 votes.
 * No re-delegation needed if balances change.
 *
 * References:
 *
 * - https://www.comp.xyz/t/governance-guide-how-to-delegate/365
 */
contract ClsToken is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using BoringMath32 for uint32;
    using SafeCast for uint256;
    using SafeCast for uint32;

    /// @dev CLA timelock.
    /// `claAmount` Amount of deposited CLAs.
    /// `endDay` When tokens are unlocked.
    struct TokenLock {
        uint256 claAmount;
        uint32 endDay;
    }

    /// @dev CLA timelock list.
    /// `lockedList` list of CLA timelock.
    /// `startIdx` start index of lockedList.
    /// `unlockableAmount` amount of CLA unlockable.
    struct TokenLockList {
        TokenLock[] lockedList;
        uint256 startIdx;
        uint256 unlockableAmount;
    }

    /// @dev TokenLockList for locked tokens.
    mapping(address => mapping(uint8 => TokenLockList)) public locked;
    /// @dev TokenLockList for claimed tokens.
    mapping(address => TokenLockList) public claimLocked;
    /// @dev Multiple to lockup period.
    mapping(uint8 => uint32) public multipleToLockup;
    /// @dev TokenLockList for migration reward.
    mapping(address => TokenLock) public migrationLocked;

    IFeeDistributor public feeDistributor;
    IClaDistributor public claDistributor;
    IERC20 public cla;
    address public masterchef;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint32 private constant CLAIM_PERIOD = 7;

    //// EVENT
    event Mint(address indexed user, address indexed to, uint256 clsAmount, uint8 indexed multiple);
    event MintClaimBoost(address indexed to, uint256 clsAmount);
    event MintMigration(address indexed to, uint256 clsAmount);
    event Burn(address indexed user, address indexed to, uint256 clsAmount, uint8 indexed multiple);
    event BurnMigration(address indexed user, address indexed to, uint256 clsAmount);
    event InstantUnlockWithPenalty(address indexed user, address indexed to, uint256 clsAmount, uint8 indexed multiple);
    event Claim(address indexed user, address indexed to, uint256 claAmount);

    function initialize(IERC20 cla_) public initializer {
        __ERC20_init("ClaimSwap Shadow", "CLS");
        __Ownable_init();
        cla = cla_;
        multipleToLockup[1] = 3 * 30;
        multipleToLockup[2] = 6 * 30;
        multipleToLockup[4] = 9 * 30;
    }
    
    function setFeeDistributor(IFeeDistributor feeDistributor_)
        public
        onlyOwner
    {
        feeDistributor = feeDistributor_;
    }

    function setClaDistributor(IClaDistributor claDistributor_)
        public
        onlyOwner
    {
        claDistributor = claDistributor_;
    }

    function setMasterchef(address masterchef_) public onlyOwner {
        masterchef = masterchef_;
    }

    // // Disable some ERC20 features
    /// @notice Cls token transfer is disabled.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal { 
        super._beforeTokenTransfer(from, to, amount);
        require(from == address(0) || to == address(0), "ClsToken: transfer disabled");
    }

    /// @notice Cls token transfer is disabled.
    function approve(address spender, uint256 amount) public returns (bool) {
        revert("ClsToken: transfer disabled");
    }

    /// @notice Cls token transfer is disabled.
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        revert("ClsToken: transfer disabled");
    }

    /// @notice Cls token transfer is disabled.
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        returns (bool)
    {
        revert("ClsToken: transfer disabled");
    }

    function _mint(address account, uint256 amount) internal {
        super._mint(account, amount);
        feeDistributor.deposit(account, amount);
        claDistributor.deposit(account, amount);
        _moveDelegates(address(0), _delegates[account], amount);
    }

    function _burn(address account, uint256 amount) internal {
        super._burn(account, amount);
        feeDistributor.withdraw(account, amount);
        claDistributor.withdraw(account, amount);
        _moveDelegates(_delegates[account], address(0), amount);
    }

    /// @dev Return unlockable amount of cla and locked list of cla
    function lockedClaInfo(address account, uint8 multiple)
        public
        view
        returns (
            uint256 unlockableAmount,
            uint256 lockedAmount,
            uint256[] memory lockedAmounts,
            uint32[] memory endDays
        )
    {
        unlockableAmount = locked[account][multiple].unlockableAmount;
        uint256 startIdx = locked[account][multiple].startIdx;
        uint256 endIdx = locked[account][multiple].lockedList.length;
        TokenLock[] memory lockedList = locked[account][multiple].lockedList;
        uint256 i = startIdx;
        uint32 currentDay = _getDay();
        for (; i < endIdx; ++i) {
            if (currentDay > lockedList[i].endDay) {
                unlockableAmount = unlockableAmount.add(
                    lockedList[i].claAmount
                );
            } else {
                break;
            }
        }
        lockedAmount = unlockableAmount;
        uint256 lockedIdx = i;
        lockedAmounts = new uint256[](endIdx - lockedIdx);
        endDays = new uint32[](endIdx - lockedIdx);
        for (; i < endIdx; ++i) {
            lockedAmounts[i - lockedIdx] = lockedList[i].claAmount;
            endDays[i - lockedIdx] = lockedList[i].endDay;
            lockedAmount = lockedAmount.add(
                lockedList[i].claAmount
            );
        }
    }

    /// @dev Return raw locked cla info
    function rawLockedClaInfo(address account, uint8 multiple)
        public
        view
        returns (
            TokenLockList memory tokenLockList
        )
    {
        tokenLockList = locked[account][multiple];
    }

    /// @dev Return claimable amount of cla and locked list of cla
    function claimLockedInfo(address account)
        public
        view
        returns (
            uint256 unlockableAmount,
            uint256 lockedAmount,
            uint256[] memory lockedAmounts,
            uint32[] memory endDays
        )
    {
        unlockableAmount = claimLocked[account].unlockableAmount;
        uint256 startIdx = claimLocked[account].startIdx;
        uint256 endIdx = claimLocked[account].lockedList.length;
        TokenLock[] memory lockedList = claimLocked[account].lockedList;
        uint256 i = startIdx;
        uint32 currentDay = _getDay();
        for (; i < endIdx; ++i) {
            if (currentDay > lockedList[i].endDay) {
                unlockableAmount = unlockableAmount.add(
                    lockedList[i].claAmount
                );
            } else {
                break;
            }
        }
        lockedAmount = unlockableAmount;
        uint256 lockedIdx = i;
        lockedAmounts = new uint256[](endIdx - lockedIdx);
        endDays = new uint32[](endIdx - lockedIdx);
        for (; i < endIdx; ++i) {
            lockedAmounts[i - lockedIdx] = lockedList[i].claAmount;
            endDays[i - lockedIdx] = lockedList[i].endDay;
            lockedAmount = lockedAmount.add(
                lockedList[i].claAmount
            );
        }
    }

    /// @dev Return raw claimed cla info
    function rawClaimLockedClaInfo(address account)
        public
        view
        returns (
            TokenLockList memory tokenLockList
        )
    {
        tokenLockList = claimLocked[account];
    }

    /// @notice Update TokenLockedList.
    /// Update unlockable amount and start idx.
    function _updateTokenLockedList(TokenLockList storage tokenLockList)
        internal
    {
        uint256 startIdx = tokenLockList.startIdx;
        uint256 endIdx = tokenLockList.lockedList.length;
        TokenLock[] storage lockedList = tokenLockList.lockedList;
        uint256 i = startIdx;
        uint256 newUnlockableAmount = 0;
        uint32 currentDay = _getDay();
        for (; i < endIdx; i++) {
            if (currentDay > lockedList[i].endDay) {
                newUnlockableAmount = newUnlockableAmount.add(
                    lockedList[i].claAmount
                );
                lockedList[i].claAmount = 0;
            } else {
                break;
            }
        }
        tokenLockList.unlockableAmount = tokenLockList.unlockableAmount.add(
            newUnlockableAmount
        );
        tokenLockList.startIdx = i;
    }

    /// @dev Lock CLAs and mint CLSs.
    /// @param to CLS Receiver.
    /// @param amount Amount of CLA to lock.
    /// @param multiple Multiple of CLA to lock.
    function mint(
        address to,
        uint256 amount,
        uint8 multiple
    ) public {
        uint32 lockupPeriod = multipleToLockup[multiple];
        require(lockupPeriod != 0, "Invalid multiple");
        require(amount > 0, "Mint amount is zero");
        uint32 endDay = _getDay().add(lockupPeriod);

        cla.safeTransferFrom(msg.sender, address(this), amount);

        TokenLockList storage tokenLockList = locked[to][multiple];
        uint256 endIdx = tokenLockList.lockedList.length;
        if (
            endIdx != 0
            && tokenLockList.lockedList[endIdx - 1].endDay == endDay
            && tokenLockList.startIdx < endIdx
        ) {
            tokenLockList.lockedList[endIdx - 1].claAmount = tokenLockList
                .lockedList[endIdx - 1]
                .claAmount
                .add(amount);
        } else {
            tokenLockList.lockedList.push(
                TokenLock({claAmount: amount, endDay: endDay})
            );
        }
        _mint(to, amount.mul(multiple));
       emit Mint(msg.sender, to, amount.mul(multiple), multiple);
    }

    /// @notice Lock CLA reward of swap fee and mint unlockable CLS
    /// Can be called by fee distributor
    /// @param to CLS reciever
    /// @param amount CLA amount 
    function mintClaimBoost(address to, uint256 amount) public {
        require(msg.sender == address(feeDistributor));
        require(amount > 0, "Mint amount is zero");
        
        cla.safeTransferFrom(msg.sender, address(this), amount);
        locked[to][1].unlockableAmount = locked[to][1].unlockableAmount.add(
            amount
        );
        _mint(to, amount);
        emit MintClaimBoost(to, amount);
    }

    /// @notice Lock CLA reward of migration period and mint 30days locked CLS
    /// Can be called by masterChef
    /// @param to CLS reciever
    /// @param amount CLA amount 
    function mintMigration(address to, uint256 amount) public {
        require(msg.sender == masterchef);
        require(amount > 0, "Mint amount is zero");
        
        cla.safeTransferFrom(msg.sender, address(this), amount);
        migrationLocked[to].claAmount = migrationLocked[to].claAmount.add(
            amount
        );
        migrationLocked[to].endDay = _getDay().add(30);
        _mint(to, amount);
        emit MintMigration(to, amount);
    }

    /// @notice Unlock CLA reward of migration period and burn CLSs.
    /// @param to CLA reciever
    /// @param amount CLA amount
    function burnMigration(address to, uint256 amount) public {
        TokenLock memory tokenLock = migrationLocked[msg.sender];
        uint32 currentDay = _getDay();
        require(amount > 0, "Burn amount is zero");
        require(tokenLock.claAmount > 0);
        require(currentDay > tokenLock.endDay);
        migrationLocked[msg.sender].claAmount = tokenLock.claAmount.sub(amount);

        _addClaimLocked(to, amount, currentDay.add(CLAIM_PERIOD));
        emit BurnMigration(msg.sender, to, amount); 
        _burn(msg.sender, amount);
    }

    // alias of mint()
    function lock(
        address to,
        uint256 amount,
        uint8 multiple
    ) public {
        mint(to, amount, multiple);
    }

    /// @dev Unlock CLAs and burn CLSs.
    /// @param to CLA receiver.
    /// @param multiple Multiple of CLA.
    /// @param amount Amount Of CLA to unlock.
    function burn(
        address to,
        uint8 multiple,
        uint256 amount
    ) public {
        uint32 lockupPeriod = multipleToLockup[multiple];
        require(lockupPeriod != 0, "Invalid multiple");
        require(amount > 0, "Burn amount is zero");
        uint32 currentDay = _getDay();

        TokenLockList storage tokenLockList = locked[msg.sender][multiple];
        _updateTokenLockedList(tokenLockList);
        tokenLockList.unlockableAmount = tokenLockList.unlockableAmount.sub(
            amount
        );

        _addClaimLocked(to, amount, currentDay.add(CLAIM_PERIOD));
        emit Burn(msg.sender, to, amount.mul(multiple), multiple);
        _burn(msg.sender, amount.mul(multiple));
    }

    // alias of burn()
    function unlock(
        address to,
        uint8 multiple,
        uint256 amount
    ) public {
        burn(to, multiple, amount);
    }

    /// @dev Unlock CLAs and burn CLSs.
    /// @param to CLA receiver.
    /// @param multiple Multiple of CLA.
    /// unlock all unlockable CLAs of selected multiple.
    function unlockAll(address to, uint8 multiple) public {
        uint32 lockupPeriod = multipleToLockup[multiple];
        require(lockupPeriod != 0, "Invalid multiple");
        uint32 currentDay = _getDay();

        TokenLockList storage tokenLockList = locked[msg.sender][multiple];
        _updateTokenLockedList(tokenLockList);
        uint256 amount = tokenLockList.unlockableAmount;
        require(amount > 0, "Unlockable amount is zero");
        tokenLockList.unlockableAmount = 0;

        _addClaimLocked(to, amount, currentDay.add(CLAIM_PERIOD));
        emit Burn(msg.sender, to, amount.mul(multiple), multiple);
        _burn(msg.sender, amount.mul(multiple));
    }

    /// @notice Unlock for all unlockable CLAs. Be careful of gas spending!
    function massUnlockAll(address to) public {
        uint256 totalClaAmount = 0;
        uint256 totalClsAmount = 0;
        uint32 currentDay = _getDay();
        for (uint8 i = 1; i <= 4; i *= 2) {
            TokenLockList storage tokenLockList = locked[msg.sender][i];
            _updateTokenLockedList(tokenLockList);
            uint256 amount = tokenLockList.unlockableAmount;
            if (amount > 0) {
                tokenLockList.unlockableAmount = 0;
                totalClaAmount = totalClaAmount.add(amount);
                totalClsAmount = totalClsAmount.add(amount.mul(i));
                emit Burn(msg.sender, to, amount, i);
            }
        }
        require(totalClaAmount > 0 && totalClsAmount > 0, "Unlockable amount is zero");
        _addClaimLocked(to, totalClaAmount, currentDay.add(CLAIM_PERIOD));
        _burn(msg.sender, totalClsAmount);
    }

    /// @notice Instant unlock with penalty function. 
    /// Only locked CLA can be unlocked instantly.
    /// @param to CLA reciever.
    /// @param multiple Multiple of CLA.
    /// @param amount Amount of CLA to unlock.
    function instantUnlockWithPenalty(
        address to,
        uint8 multiple,
        uint256 amount
    ) public {
        uint32 lockupPeriod = multipleToLockup[multiple];
        require(lockupPeriod != 0, "Invalid multiple");
        _updateTokenLockedList(locked[msg.sender][multiple]);
        uint256 startIdx = locked[msg.sender][multiple].startIdx;
        uint256 endIdx = locked[msg.sender][multiple].lockedList.length;
        TokenLock[] storage lockedList = locked[msg.sender][multiple]
            .lockedList;

        uint256 unlockedAmount = 0;
        uint256 i = startIdx;
        for (; i < endIdx; ++i) {
            uint256 claAmount = lockedList[i].claAmount;
            if (unlockedAmount.add(claAmount) <= amount) {
                lockedList[i].claAmount = 0;
                unlockedAmount = unlockedAmount.add(claAmount);
            } else {
                lockedList[i].claAmount = claAmount.add(unlockedAmount).sub(
                    amount
                );
                unlockedAmount = amount;
                break;
            }
        }
        assert(amount == unlockedAmount);
        locked[msg.sender][multiple].startIdx = i;
        _burn(msg.sender, unlockedAmount.mul(multiple));
        uint256 burnedAmount = unlockedAmount.mul(3) / 10;
        uint256 transferAmount = unlockedAmount.sub(burnedAmount);
        cla.safeTransfer(BURN_ADDRESS, burnedAmount);
        cla.safeTransfer(to, transferAmount);
        emit InstantUnlockWithPenalty(msg.sender, to, unlockedAmount.mul(multiple), multiple);
    }

    /// @dev Claim all claimable CLAs.
    /// @param to CLA receiver.
    function claim(address to) public {
        TokenLockList storage tokenLockList = claimLocked[msg.sender];
        _updateTokenLockedList(tokenLockList);
        uint256 amount = tokenLockList.unlockableAmount;
        require(amount > 0, "nothing to claim");
        tokenLockList.unlockableAmount = 0;
        cla.safeTransfer(to, amount);
        emit Claim(msg.sender, to, amount);
    }

    /// @dev Push CLA into claimLocked
    /// @param to CLA receiver.
    /// @param amount Amount of CLAs.
    /// @param endDay End day of locked period.
    function _addClaimLocked(
        address to,
        uint256 amount,
        uint32 endDay
    ) internal {
        uint256 endIdx = claimLocked[to].lockedList.length;
        if (
            endIdx != 0 &&
            claimLocked[to].lockedList[endIdx - 1].endDay == endDay
        ) {
            claimLocked[to].lockedList[endIdx - 1].claAmount = claimLocked[to]
                .lockedList[endIdx - 1]
                .claAmount
                .add(amount);
        } else {
            claimLocked[to].lockedList.push(
                TokenLock({claAmount: amount, endDay: endDay})
            );
        }
    }

    function _getDay() private view returns (uint32) {
        return (block.timestamp / 1 days).toUint32();
    }

    function emergencyAdjustStartIdx(address account, uint8 multiple) public onlyOwner {
        TokenLock[] memory lockedList = locked[account][multiple].lockedList;
        uint256 endIdx = lockedList.length;
        for (uint256 i = 0; i < endIdx; i++) {
            if(lockedList[i].claAmount != 0){
                locked[account][multiple].startIdx = i;
                break;
            }
        }
    }

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @notice A record of each accounts delegate
    mapping(address => address) internal _delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(
        address indexed delegate,
        uint256 previousBalance,
        uint256 newBalance
    );

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator) external view returns (address) {
        return _delegates[delegator];
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return
            nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint256)
    {
        require(
            blockNumber < block.number,
            "CLS::getPriorVotes: not yet determined"
        );

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying CLSs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(
        address srcRep,
        address dstRep,
        uint256 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0
                    ? checkpoints[srcRep][srcRepNum - 1].votes
                    : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0
                    ? checkpoints[dstRep][dstRepNum - 1].votes
                    : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        uint32 blockNumber = safe32(
            block.number,
            "CLS::_writeCheckpoint: block number exceeds 32 bits"
        );

        if (
            nCheckpoints > 0 &&
            checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber
        ) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(
                blockNumber,
                newVotes
            );
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint256 n, string memory errorMessage)
        internal
        pure
        returns (uint32)
    {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

}