// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/SafeCast.sol";
import "./ClaimToken.sol";
import "../interfaces/IMiningTreasury.sol";
import "../interfaces/IRewarder.sol";
import "../codes/Ownable.sol";

interface IMigrator {
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    function migrate(IERC20 token) external returns (IERC20);
}

interface IClsToken {
    // Transfer cla token to cls contract and mint cls token to `to` address
    function mintMigration(address to, uint256 amount) external;
}

/**
 * @title MasterChef of CLA.
 *
 * References:
 *
 * - https://github.com/sushiswap/sushiswap/blob/canary/contracts/MasterChef.sol
 * - https://github.com/sushiswap/sushiswap/blob/canary/contracts/MasterChefV2.sol
 */
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of CLA entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
        bool migrated;
    }

    struct UserMigrationInfo {
        uint256 amount;
        uint256 amountSent;
    }

    /// @notice Info of each pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of CLA to distribute per block.
    struct PoolInfo {
        uint256 accClaPerShare;
        uint256 lastRewardBlock;
        uint256 allocPoint;
    }

    /// @notice Address of CLA contract.
    ClaimToken public cla;
    /// @notice Address of CLS contract.
    IClsToken public cls;
    /// @notice Multiplier address.
    address public multiple;
    /// @notice mining treasury address.
    IMiningTreasury public miningTreasury;

    /// @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigrator public migrator;
    uint256[] public migrationAccClaPerShare;
    /// @notice Info of each pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract.
    IRewarder[] public rewarder;
    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => UserMigrationInfo)) public userMigrationInfo;

    uint8 public migrationPoolLength;
    /// @notice The block number when lp token migration ends.
    uint256 public migrationEndBlock;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    uint256 public startBlock; /// @dev mining start block
    /// @notice Reward ratio between LP staker and CLA staker
    uint256 public lpRewardRatio;
    uint256 private constant CLA_REWARD_RATIO_DIVISOR = 1e12;
    uint256 private constant ACC_CLA_PRECISION = 1e12;
    uint256 private constant YEAR = 12 * 30 * 24 * 60 * 60; // Blocks
    /// @notice Address of KSP contract.
    address private constant KSP = 0xC6a2Ad8cC6e4A7E08FC37cC5954be07d499E7654;

    event Deposit(
        address indexed user,
        uint256 indexed pId,
        uint256 amount,
        address indexed to
    );
    event Withdraw(
        address indexed user,
        uint256 indexed pId,
        uint256 amount,
        address indexed to
    );
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pId,
        uint256 amount,
        address indexed to
    );
    event Harvest(address indexed user, uint256 indexed pId, uint256 amount);
    event PoolAddition(
        uint256 indexed pId,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        IRewarder indexed rewarder
    );
    event SetPool(
        uint256 indexed pId,
        uint256 allocPoint,
        IRewarder indexed rewarder,
        bool overwrite
    );
    event UpdatePool(
        uint256 indexed pId,
        uint256 lastRewardBlock,
        uint256 lpSupply,
        uint256 accClaPerShare
    );
    event UpdateLpRewardRatio(uint256 lpRewardRatio);

    /// @param cla_ The CLA token contract address.
    constructor(
        ClaimToken cla_,
        IMiningTreasury miningTreasury_,
        uint256 startBlock_,
        uint256 migrationEndBlock_
    ) public {
        cla = cla_;
        miningTreasury = miningTreasury_;
        startBlock = startBlock_;
        migrationEndBlock = migrationEndBlock_;
    }

    /// @notice withdraw ksp token from master chef contract. Can only be called by the owner,
    /// @param to address of ksp receiver
    function withdrawKSP(address to) public onlyOwner {
        uint256 amount = IERC20(KSP).balanceOf(address(this));
        IERC20(KSP).transfer(to, amount);
    }

    /// @notice set lp reward ratio. Can Only be called by mining treasury contract.
    /// @param lpRewardRatio_ lpreward ratio
    /// @param withUpdate mass update pool flag
    function setLpRewardRatio(uint256 lpRewardRatio_, bool withUpdate) public {
        require(msg.sender == address(miningTreasury), "not mining treasury");
        if (withUpdate) {
            massUpdatePools();
        }
        lpRewardRatio = lpRewardRatio_;
        emit UpdateLpRewardRatio(lpRewardRatio);
    }

    function claPerBlock() public view returns (uint256) {
        return _claPerBlock(block.number);
    }

    /// @notice Number of tokens created per block.
    function _claPerBlock(uint256 blockNumber) internal view returns (uint256) {
        if (blockNumber < startBlock + 2 * YEAR) {
            return ((9e17 / CLA_REWARD_RATIO_DIVISOR) * lpRewardRatio);
        } else if (blockNumber < startBlock + 2 * 2 * YEAR) {
            return ((6e17 / CLA_REWARD_RATIO_DIVISOR) * lpRewardRatio);
        } else if (blockNumber < startBlock + 2 * 3 * YEAR) {
            return ((3e17 / CLA_REWARD_RATIO_DIVISOR) * lpRewardRatio);
        } else {
            return 0;
        }
    }

    /// @notice Return reward multiplier over the given _from to _to block.
    function claPerBlocks(uint256 from, uint256 to)
        public
        view
        returns (uint256)
    {
        require(from <= to);
        uint256 claPerBlockFrom = _claPerBlock(from);
        uint256 claPerBlockTo = _claPerBlock(to);
        if (claPerBlockFrom == claPerBlockTo)
            return to.sub(from).mul(claPerBlockFrom);
        uint256 boundary = (to.sub(startBlock) / (2 * YEAR)).mul(2 * YEAR).add(
            startBlock
        );
        return
            claPerBlockFrom.mul(boundary.sub(from)).add(
                claPerBlockTo.mul(to.sub(boundary))
            );
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// Pool of zero (0) index MUST be Cla-Klay lp token.
    /// @param allocPoint AP of the new pool.
    /// @param lpToken_ Address of the LP ERC-20 token.
    /// @param rewarder_ Address of the rewarder delegate.
    /// @param withUpdate True if mass update pool before update pool
    function add(
        uint256 allocPoint,
        IERC20 lpToken_,
        IRewarder rewarder_,
        bool withUpdate
    ) public onlyOwner {
        if (withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(lpToken_);
        rewarder.push(rewarder_);
        migrationAccClaPerShare.push(0);
        poolInfo.push(
            PoolInfo({
                allocPoint: allocPoint,
                lastRewardBlock: lastRewardBlock,
                accClaPerShare: 0
            })
        );
        emit PoolAddition(
            lpToken.length.sub(1),
            allocPoint,
            lpToken_,
            rewarder_
        );
    }

    /// @notice Update the given pool's CLA allocation point and `IRewarder` contract.
    /// Can only be called by the owner.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param allocPoint New AP of the pool.
    /// @param rewarder_ Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    /// @param withUpdate True if mass update pool before update pool
    function set(
        uint256 pId,
        uint256 allocPoint,
        IRewarder rewarder_,
        bool overwrite,
        bool withUpdate
    ) public {
        require(
            (owner() == msg.sender) || (multiple == msg.sender),
            "Ownable: caller is not the owner||multiple"
        );
        if (withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[pId].allocPoint).add(
            allocPoint
        );
        poolInfo[pId].allocPoint = allocPoint;
        if (overwrite) {
            rewarder[pId] = rewarder_;
        }
        emit SetPool(
            pId,
            allocPoint,
            overwrite ? rewarder_ : rewarder[pId],
            overwrite
        );
    }

    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param migrator_ The contract address to set.
    function setMigrator(IMigrator migrator_) public onlyOwner {
        migrator = migrator_;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @notice onlyOnwer to protect from front running attack
    function migrate(uint256 pId) public onlyOwner {
        require(
            address(migrator) != address(0),
            "MasterChefV2: no migrator set"
        );
        IERC20 _lpToken = lpToken[pId];
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(
            bal == newLpToken.balanceOf(address(this)),
            "MasterChefV2: migrated balance must match"
        );
        lpToken[pId] = newLpToken;
    }

    /// @notice View function to see pending CLA on frontend.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param user_ Address of user.
    /// @return pending CLA reward for a given user.
    function pendingCla(uint256 pId, address user_)
        external
        view
        returns (uint256 pending)
    {
        PoolInfo memory pool = poolInfo[pId];
        UserInfo storage user = userInfo[pId][user_];
        uint256 accClaPerShare = pool.accClaPerShare;
        uint256 lpSupply = lpToken[pId].balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 claRewardPerBlocks = claPerBlocks(
                pool.lastRewardBlock,
                block.number
            );
            uint256 claReward = claRewardPerBlocks.mul(pool.allocPoint) /
                totalAllocPoint;

            if (claReward != 0) {
                accClaPerShare = accClaPerShare.add(
                    (claReward.mul(ACC_CLA_PRECISION) / lpSupply)
                );
            }
        }
        pending = int256(user.amount.mul(accClaPerShare) / ACC_CLA_PRECISION)
            .sub(user.rewardDebt)
            .toUint256();
    }

    function pendingMigrationCla(uint256 pId, address user_)
        external
        view
        returns (uint256 pending)
    {
        require(pId < migrationPoolLength, "not migration pool");
        UserInfo storage user = userInfo[pId][user_];
        if(user.migrated == true){
            UserMigrationInfo memory migrationUser = userMigrationInfo[pId][user_];
            pending = migrationUser.amount - migrationUser.amountSent;
        }else{
            int256 accumulatedCla = int256(
                user.amount.mul(migrationAccClaPerShare[pId]) / ACC_CLA_PRECISION
            );
            if(accumulatedCla > user.rewardDebt)
                pending = uint256(accumulatedCla - user.rewardDebt);
        }
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(i);
        }
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pIds Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pIds) external {
        uint256 len = pIds.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pIds[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pId) public returns (PoolInfo memory pool) {
        pool = poolInfo[pId];
        if (block.number > pool.lastRewardBlock && totalAllocPoint > 0) {
            uint256 lpSupply = lpToken[pId].balanceOf(address(this));
            if (lpSupply > 0) {
                if (
                    pId < migrationPoolLength &&
                    migrationAccClaPerShare[pId] == 0 &&
                    block.number >= migrationEndBlock
                ) {
                    uint256 transferAmount = 0;
                    uint256 migrationClaRewardPerBlocks = claPerBlocks(
                        pool.lastRewardBlock,
                        migrationEndBlock
                    );
                    uint256 migrationClaReward = migrationClaRewardPerBlocks
                        .mul(pool.allocPoint) / totalAllocPoint;
                    if (migrationClaReward != 0) {
                        transferAmount += migrationClaReward;
                        pool.accClaPerShare = pool.accClaPerShare.add(
                            (migrationClaReward.mul(ACC_CLA_PRECISION) /
                                lpSupply)
                        );
                    }
                    migrationAccClaPerShare[pId] = pool.accClaPerShare;
                    uint256 claRewardPerBlocks = claPerBlocks(
                        migrationEndBlock,
                        block.number
                    );
                    uint256 claReward = claRewardPerBlocks.mul(
                        pool.allocPoint
                    ) / totalAllocPoint;
                    if (claReward != 0) {
                        transferAmount += claReward;
                        pool.accClaPerShare = pool.accClaPerShare.add(
                            (claReward.mul(ACC_CLA_PRECISION) / lpSupply)
                        );
                    }
                    if (transferAmount != 0) {
                        miningTreasury.transfer(transferAmount);
                    }
                } else {
                    uint256 claRewardPerBlocks = claPerBlocks(
                        pool.lastRewardBlock,
                        block.number
                    );
                    uint256 claReward = claRewardPerBlocks.mul(
                        pool.allocPoint
                    ) / totalAllocPoint;

                    if (claReward != 0) {
                        miningTreasury.transfer(claReward);
                        pool.accClaPerShare = pool.accClaPerShare.add(
                            (claReward.mul(ACC_CLA_PRECISION) / lpSupply)
                        );
                    }
                }
            }
            pool.lastRewardBlock = block.number;
            poolInfo[pId] = pool;
            emit UpdatePool(
                pId,
                pool.lastRewardBlock,
                lpSupply,
                pool.accClaPerShare
            );
        }
    }

    /// @notice Deposit LP tokens to MCV2 for CLA allocation.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(
        uint256 pId,
        uint256 amount,
        address to
    ) public {
        PoolInfo memory pool = updatePool(pId);
        UserInfo storage user = userInfo[pId][to];
        if (
            pId < migrationPoolLength &&
            !user.migrated &&
            block.number >= migrationEndBlock
        ) {
            _setUserMigrationInfo(pId, to, user);
        }
        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(
            int256(amount.mul(pool.accClaPerShare) / ACC_CLA_PRECISION)
        );

        // Interactions
        IRewarder _rewarder = rewarder[pId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(pId, to, to, 0, user.amount);
        }

        lpToken[pId].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pId, amount, to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(
        uint256 pId,
        uint256 amount,
        address to
    ) public {
        if (pId != 0) {
            require(block.number >= migrationEndBlock, "not yet");
        }

        PoolInfo memory pool = updatePool(pId);
        UserInfo storage user = userInfo[pId][msg.sender];
        if (
            pId < migrationPoolLength &&
            !user.migrated &&
            block.number >= migrationEndBlock
        ) {
            _setUserMigrationInfo(pId, msg.sender, user);
        }
        // Effects
        user.rewardDebt = user.rewardDebt.sub(
            int256(amount.mul(pool.accClaPerShare) / ACC_CLA_PRECISION)
        );
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarder _rewarder = rewarder[pId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(pId, msg.sender, to, 0, user.amount);
        }

        lpToken[pId].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pId, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param to Receiver of CLA rewards.
    function harvest(uint256 pId, address to) public {
        require(block.number >= migrationEndBlock, "not yet");
        PoolInfo memory pool = updatePool(pId);
        UserInfo storage user = userInfo[pId][msg.sender];
        if (pId < migrationPoolLength && !user.migrated) {
            _setUserMigrationInfo(pId, msg.sender, user);
        }

        int256 accumulatedCla = int256(
            user.amount.mul(pool.accClaPerShare) / ACC_CLA_PRECISION
        );
        uint256 _pendingCla = accumulatedCla.sub(user.rewardDebt).toUint256();

        // Effects
        user.rewardDebt = accumulatedCla;

        // Interactions
        if (_pendingCla != 0) {
            _safeClaTransfer(to, _pendingCla);
        }

        IRewarder _rewarder = rewarder[pId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(
                pId,
                msg.sender,
                to,
                _pendingCla,
                user.amount
            );
        }

        emit Harvest(msg.sender, pId, _pendingCla);
    }

    /// @notice harvest migration reward
    function migrationHarvest(uint256 pId, address to) public {
        require(block.number >= migrationEndBlock, "not yet");
        require(pId < migrationPoolLength, "This pool is not for migration");
        updatePool(pId);
        UserInfo storage user = userInfo[pId][msg.sender];
        if (!user.migrated) {
            _setUserMigrationInfo(pId, msg.sender, user);
        }
        UserMigrationInfo storage userMigration = userMigrationInfo[pId][msg.sender];
        uint256 _pendingCla = userMigration.amount.sub(
            userMigration.amountSent
        );
        if (_pendingCla != 0) {
            userMigration.amountSent = _pendingCla;
            cla.approve(address(cls), _pendingCla);
            cls.mintMigration(to, _pendingCla);
        }
        emit Harvest(msg.sender, pId, _pendingCla);
    }

    function migrationHarvestAll(address to) public {
        uint256 len = migrationPoolLength;
        for (uint256 i = 0; i < len; i++) {
            migrationHarvest(i, to);
        }
    }

    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and CLA rewards.
    function withdrawAndHarvest(
        uint256 pId,
        uint256 amount,
        address to
    ) public {
        require(block.number >= migrationEndBlock, "not yet");
        PoolInfo memory pool = updatePool(pId);
        UserInfo storage user = userInfo[pId][msg.sender];
        if (pId < migrationPoolLength && !user.migrated) {
            _setUserMigrationInfo(pId, msg.sender, user);
        }

        int256 accumulatedCla = int256(
            user.amount.mul(pool.accClaPerShare) / ACC_CLA_PRECISION
        );
        uint256 _pendingCla = accumulatedCla.sub(user.rewardDebt).toUint256();

        // Effects
        user.rewardDebt = accumulatedCla.sub(
            int256(amount.mul(pool.accClaPerShare) / ACC_CLA_PRECISION)
        );
        user.amount = user.amount.sub(amount);

        // Interactions
        _safeClaTransfer(to, _pendingCla);

        IRewarder _rewarder = rewarder[pId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(
                pId,
                msg.sender,
                to,
                _pendingCla,
                user.amount
            );
        }

        lpToken[pId].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pId, amount, to);
        emit Harvest(msg.sender, pId, _pendingCla);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pId The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pId, address to) public {
        UserInfo storage user = userInfo[pId][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onClaReward(pId, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pId].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pId, amount, to);
    }

    /// @notice Safe CLA transfer function, just in case if rounding error causes pool to not have enough CLAs.
    /// @param to address of cla reciever
    /// @param amount amount of cla to transfer
    function _safeClaTransfer(address to, uint256 amount) internal {
        uint256 claBalance = cla.balanceOf(address(this));
        if (amount > claBalance) {
            cla.transfer(to, claBalance);
        } else {
            cla.transfer(to, amount);
        }
    }

    /// @notice Update multiplier address. Can only be called by the owner or previous multiplier address
    /// @param multiple_ Address of multiplier address
    function setMultiple(address multiple_) public {
        require(
            (owner() == msg.sender) || (multiple == msg.sender),
            "multiple: wut?"
        );
        multiple = multiple_;
    }

    function setCls(IClsToken cls_) public onlyOwner {
        cls = cls_;
    }

    function setMiningTreasury(IMiningTreasury miningTreasury_) public onlyOwner {
        miningTreasury = miningTreasury_;
    }

    /// @notice Update migration pool length.
    /// @param length length of migration pools
    function setMigrationPoolLength(uint8 length) public onlyOwner {
        migrationPoolLength = length;
    }

    /// @notice Update user migration info. internal function
    /// @param pId poolid
    /// @param user user address
    /// @param userInfo userInfo
    function _setUserMigrationInfo(
        uint256 pId,
        address user,
        UserInfo storage userInfo
    ) internal {
        UserMigrationInfo storage userMigration = userMigrationInfo[pId][user];
        userInfo.migrated = true;
        int256 accmulatedCla = int256(
            userInfo.amount.mul(migrationAccClaPerShare[pId]) /
                ACC_CLA_PRECISION
        );
        uint256 _pendingCla = accmulatedCla
            .sub(userInfo.rewardDebt)
            .toUint256();
        if (_pendingCla != 0) {
            userInfo.rewardDebt = accmulatedCla;
            userMigration.amount = _pendingCla;
        }
    }
}
