pragma solidity ^0.8.10;

import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";
import {LibStableSwap, StableSwapStorage, FEE_DENOMINATOR, PRECISION} from "../libraries/LibStableSwap.sol";
import {IERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-4.8.1/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Curve implementation contracts only for 2pool
contract StableSwap2PoolFacet {
    using SafeERC20 for IERC20;

    event TokenExchange(
        address indexed buyer,
        uint256 sold_id,
        uint256 tokens_sold,
        uint256 bought_id,
        uint256 tokens_bought
    );
    event AddLiquidity(
        address indexed provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 invariant,
        uint256 token_supply
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 token_supply
    );
    event RemoveLiquidityOne(address indexed provider, uint256 index, uint256 token_amount, uint256 coin_amount);
    event RemoveLiquidityImbalance(
        address indexed provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 invariant,
        uint256 token_supply
    );

    event Transfer(address indexed from, address indexed to, uint256 value);

    // VIEW FUNCTION OF STABLE SWAP STORAGE

    function coin_length() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.coins.length;
    }

    function PRECISION_MUL(uint256 i) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.PRECISION_MUL[i];
    }

    function RATES(uint256 i) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.RATES[i];
    }

    function coins(uint256 i) external view returns (address) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.coins[i];
    }

    function balances(uint256 i) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.balances[i];
    }

    function fee() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.fee;
    }

    function admin_fee() external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        return ss.admin_fee;
    }

    function lp_token() external view returns (address) {
        return address(this);
    }

    function A() external view returns (uint256) {
        return _get_A();
    }

    /// @notice The current price of the pool LP token relative to the underlying pool assets. Given as an integer with 1e18 precision.
    /// @return The current price of the pool LP token
    function get_virtual_price() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        /**
        Returns portfolio virtual price (for calculating profit)
        scaled up by 1e18
        */
       uint256 D = _get_D(_xp(), _get_A());
        /**
        D is in the units similar to DAI (e.g. converted to precision 1e18)
        When balanced, D = n * x_u - total virtual value of the portfolio
        */
        if (s.totalSupply == 0) {
            return 0;
        }
        return (D * PRECISION) / s.totalSupply;
    }

    /// @notice Calculate addition or reduction in token supply from a deposit or withdrawl
    /// @param amounts array of each coin being deposited
    /// @param deposit true if deposit, false if withdrawal
    /// @return the expected amount of LP tokens received. This calculation accounts for slippage, but not fees.
    function calc_token_amount(uint256[] memory amounts, bool deposit) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256[] memory _balances = ss.balances;
        uint256 amp = _get_A();
        uint256 D0 = _get_D_mem(ss.RATES, _balances, amp);
        if (deposit) {
            for (uint256 i = 0; i < 2; i++) {
                _balances[i] += amounts[i];
            }
        } else {
            for (uint256 i = 0; i < 2; i++) {
                _balances[i] -= amounts[i];
            }
        }
        uint256 D1 = _get_D_mem(ss.RATES, _balances, amp);
        uint256 difference;
        if (deposit) {
            difference = D1 - D0;
        } else {
            difference = D0 - D1;
        }
        
        if (s.totalSupply == 0) { // when first depositing
            return D1;
        } else {
            return (difference * s.totalSupply) / D0;
        }
    }

    /// @notice Calculate amount of coin i taken when exchanging for coin j
    /// @dev use it for get amount in
    /// @param i : trade in
    /// @param j : trade out
    /// @param dy : amount of coin j to trade out
    /// @return amount of coin i to trade in
    function get_dx(
        uint256 i,
        uint256 j,
        uint256 dy
    ) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256[] memory rates = ss.RATES;
        uint256[] memory xp = _xp();

        uint256 y_after_trade = xp[j] - ((dy * rates[j]) / PRECISION * FEE_DENOMINATOR / (FEE_DENOMINATOR - ss.fee));
        uint256 x = _get_y(j, i, y_after_trade, xp);
        uint256 dx = (x - xp[i]) * PRECISION / rates[i];
        return dx + 1; // rounding error
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256[] memory rates = ss.RATES;
        uint256[] memory xp = _xp();

        uint256 x = xp[i] + ((dx * rates[i]) / PRECISION);
        uint256 y = _get_y(i, j, x, xp); 
        uint256 dy = xp[j] - y - 1;
        uint256 _fee = (ss.fee * dy) / FEE_DENOMINATOR;
        return ((dy - _fee) * PRECISION) / rates[j];
    }

    /// @notice 
    /// @param i : trade in
    /// @param j : trade out
    /// @param dx : amount of coin i to trade in
    /// @return amount of coin j to trade out
    function get_dy_underlying(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        // dx and dy in underlying units
        uint256[] memory precisions = ss.PRECISION_MUL;
        uint256[] memory xp = _xp();

        uint256 x = xp[i] + dx * precisions[i];
        uint256 y = _get_y(i, j, x, xp);
        uint256 dy = (xp[j] - y - 1);
        uint256 _fee = (ss.fee *dy) / FEE_DENOMINATOR;
        return ((dy - _fee) * PRECISION) / precisions[j];
    }

    /// @notice Perform an exchange between two coins. (curve docs)
    /// @param i: Index value for the coin to send
    /// @param j: Index value of the coin to receive
    /// @param dx: Amount of coin i to send
    /// @param min_dy: Minimum amount of coin j to receive
    /// @return Returns the amount of coin j received. Index values can be found via the coins public getter method
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(!ss.paused, "Paused");
        {
            address iAddress = ss.coins[i];
            IERC20(iAddress).safeTransferFrom(msg.sender, address(this), dx);
        }
        uint256[] memory xp = _xp_mem(ss.RATES, ss.balances);
        uint256 x = xp[i] + (dx * ss.RATES[i]) / PRECISION;
        uint256 y = _get_y(i, j, x, xp);

        uint256 dy = xp[j] - y - 1; //  -1 just in case there were some rounding errors
        uint256 dy_fee = (dy * ss.fee) / FEE_DENOMINATOR;

        // Convert all to real units
        dy = ((dy - dy_fee) * PRECISION) / ss.RATES[j];
        require(dy >= min_dy, "SlippageError");

        uint256 dy_admin_fee = (dy_fee * ss.admin_fee) / FEE_DENOMINATOR;
        dy_admin_fee = (dy_admin_fee * PRECISION) / ss.RATES[j];

        // Change balances exactly in same way as we change actual ERC20 coin amounts
        ss.balances[i] += dx;
        // When rounding errors happen, we undercharge admin fee in favor of LP
        ss.balances[j] -= dy + dy_admin_fee;

        {
            address jAddress = ss.coins[j];
            IERC20(jAddress).safeTransfer(msg.sender, dy);
        }
        emit TokenExchange(msg.sender, i, dx, j, dy);
        return dy;
    }

    /// @notice Deposit coin into the pool
    /// @param amounts List of amounts of coins to deposit
    /// @param min_mint_amount Minimum amount of LP tokens to mint from the deposit
    function add_liquidity(uint256[] memory amounts, uint256 min_mint_amount) external returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(!ss.paused, "Paused");
        
        uint256 amp = _get_A();

        uint256 D0;
        uint256[] memory old_balances = ss.balances;
        if (s.totalSupply > 0) {
            D0 = _get_D_mem(ss.RATES, old_balances, amp);
        }
        uint256[] memory new_balances = old_balances;
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = amounts[i];
            if (s.totalSupply == 0) {
                require(amount > 0, "Initial deposit requires all coins");
            }
            // Take coins from the sender
            if (amount  > 0) {
                IERC20(ss.coins[i]).safeTransferFrom(msg.sender, address(this), amount);
            }
            new_balances[i] += amount;
        }
        // Invariant after change
        uint256 D1 = _get_D_mem(ss.RATES, new_balances, amp);
        require(D1 > D0, "D1 mus be greater than D0");

        // We need to recalculate the invariant accounting for fees
        // to calculate fair user's share
        uint256 D2 = D1;
        uint256[] memory fees = new uint256[](2);
        if (s.totalSupply > 0) {
            uint256 _fee = (ss.fee * 2) / (4 * (2 - 1));
            // Only account for fees if we are not the first to deposit
                for (uint256 i = 0; i < 2; i++) {
                uint256 ideal_balance = (D1 * old_balances[i]) / D0;
                uint256 difference;
                if (ideal_balance > new_balances[i]) {
                    difference = ideal_balance - new_balances[i];
                } else {
                    difference = new_balances[i] - ideal_balance;
                }
                fees[i] = (_fee * difference) / FEE_DENOMINATOR;
                ss.balances[i] = new_balances[i] - ((fees[i] * ss.admin_fee) / FEE_DENOMINATOR);
                new_balances[i] -= fees[i];
            }
            D2 = _get_D_mem(ss.RATES, new_balances, amp);
        } else {
            ss.balances = new_balances;
        }

        // Calculate and Mint LP Token
        uint256 mint_amount;
        {
            if (s.totalSupply == 0) {
                mint_amount = D1; // Take the dust if there was any
                // mint_amount = D1
            } else {
                mint_amount = (s.totalSupply * (D2 - D0)) / D0;
            }
            require(mint_amount >= min_mint_amount, "SlippageError");
            {
                s.totalSupply += mint_amount;
                unchecked {
                    // Overflow not possible: balance + amount is at most totalSupply + amount, which is checked above.
                    s.balances[msg.sender] += mint_amount;
                }
                emit Transfer(address(0), msg.sender, mint_amount);
            }
            emit AddLiquidity(msg.sender, amounts, fees, D1, s.totalSupply);
        }
        return mint_amount;
    }

    /// @notice Withdraw coins from pool. (curve docs)
    /// @param _amount: Amount of LP tokens to burn
    /// @param min_amounts: Minimum amounts of coins to receive
    /// @return Returns a list of the amounts for each coin that was withdrawn.
    function remove_liquidity(
        uint256 _amount,
        uint256[] memory min_amounts
    ) external returns (uint256[] memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 tokenSupply = s.totalSupply;
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(!ss.paused, "Paused");
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory fees = new uint256[](2); //Fees are unused but we've got them historically in event
        
        for (uint256 i = 0; i < 2; i++) {
            uint256 value = (ss.balances[i] * _amount) / tokenSupply;
            require(value >= min_amounts[i], "Withdrawal resulted in fewer coins than expected");
            ss.balances[i] -= value;
            amounts[i] = value;
            IERC20(ss.coins[i]).safeTransfer(msg.sender, value);
        }

        {
            uint256 accountBalance = s.balances[msg.sender];
            require(accountBalance >= _amount, "ERC20: burn amount exceeds balance");
            unchecked {
                s.balances[msg.sender] = accountBalance - _amount;
                s.totalSupply -= _amount;
            }
            emit Transfer(msg.sender, address(0), _amount);
        }
        emit RemoveLiquidity(msg.sender, amounts, fees, s.totalSupply);
        return amounts;
    }

    /// @notice Withdraw coins from the pool in an imbalanced amount.
    /// @param amounts: List of amounts of underlying coins to withdraw
    /// @param max_burn_amount: Maximum amount of LP tokens to burn
    /// @return Returns actual amount of the LP tokens burned in the withdrawal.    
    function remove_liquidity_imbalance(
        uint256[] memory amounts, 
        uint256 max_burn_amount
    ) external returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(!ss.paused, "Paused");
        require(s.totalSupply > 0, "dev: zero total supply");
        
        uint256 _admin_fee = ss.admin_fee;
        uint256 amp = _get_A();

        uint256[] memory old_balances = ss.balances;
        uint256[] memory new_balances = old_balances;
        uint256 D0 = _get_D_mem(ss.RATES, old_balances, amp);
        for (uint256 i = 0; i < 2; i++) {
            new_balances[i] -= amounts[i];
        }
        uint256 D1 = _get_D_mem(ss.RATES, new_balances, amp);
        uint256[] memory fees = new uint256[](2);
        {
            uint256 _fee = (ss.fee * 2) / (4 * (2 - 1));
            for (uint256 i = 0; i < 2; i++) {
                uint256 ideal_balance = (D1 * old_balances[i]) / D0;
                uint256 difference;
                if (ideal_balance > new_balances[i]) {
                    difference = ideal_balance - new_balances[i];
                } else {
                    difference = new_balances[i] - ideal_balance;
                }
                fees[i] = (_fee * difference) / FEE_DENOMINATOR;
                ss.balances[i] = new_balances[i] - ((fees[i] * _admin_fee) / FEE_DENOMINATOR);
                new_balances[i] -= fees[i];
            }
        }
        uint256 D2 = _get_D_mem(ss.RATES, new_balances, amp);
        // BURN LP TOKENS
        uint256 token_amount = ((D0 - D2) *  s.totalSupply) / D0;
        require(token_amount > 0, "token_amount must be greater than 0");
        token_amount += 1; // In case of rounding errors - make it unfavorable for the "attacker"
        require(token_amount <= max_burn_amount, "Slippage Error");
        {
            uint256 accountBalance = s.balances[msg.sender];
            require(accountBalance >= token_amount, "ERC20: burn amount exceeds balance");
            unchecked {
                s.balances[msg.sender] = accountBalance - token_amount;
                s.totalSupply -= token_amount;
            }
            emit Transfer(msg.sender, address(0), token_amount);
        }
        // TRANSFER TOKENS
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = amounts[i];
            if (amount > 0) {
                IERC20(ss.coins[i]).safeTransfer(msg.sender, amount);
            }
        }
        emit RemoveLiquidityImbalance(msg.sender, amounts, fees, D1,  s.totalSupply);
        return token_amount;
    }

    /// @notice Calculate the amount received when withdrawing a single coin.
    /// @param token_amount: Amount of LP tokens to burn in the withdrawal
    /// @param i: Index value for the coin to withdraw
    /// @return Amount of coin to receive
    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 tokenSupply = s.totalSupply;
        (uint256 dy, ) = _calc_withdraw_one_coin(token_amount, i, tokenSupply);
        return dy;
    }
    
    /// @notice Withdraw a single coin from the pool.
    /// @param token_amount Amount of LP tokens to burn in the withdrawal
    /// @param i Index value of the coin to withdraw
    /// @param min_amount Minimum amount of coin to receive
    /// @return Returns the amount of coin i received.
    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();

        // Remove _amount of liquidity all in a form of coin i
        require(!ss.paused, "Paused");
        (uint256 dy, uint256 dy_fee) = _calc_withdraw_one_coin(token_amount, i, s.totalSupply);
        require(dy >= min_amount, "SlippageError");

        ss.balances[i] -= (dy + (dy_fee * ss.admin_fee) / FEE_DENOMINATOR);

        {
            uint256 accountBalance = s.balances[msg.sender];
            require(accountBalance >= token_amount, "ERC20: burn amount exceeds balance");
            unchecked {
                s.balances[msg.sender] = accountBalance - token_amount;
                s.totalSupply -= token_amount;
            }
            emit Transfer(msg.sender, address(0), token_amount);
        }
        IERC20(ss.coins[i]).safeTransfer(msg.sender, dy);

        emit RemoveLiquidityOne(msg.sender, i, token_amount, dy);
        return dy;
    }

    // A mean amplification coefficient for the pool
    // internal view function that returns the current A
    function _get_A() internal view returns (uint256) {
        //Handle ramping A up or down
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        uint256 t1 = ss.future_A_time;
        uint256 A1 = ss.future_A;
        if (block.timestamp < t1) {
            uint256 A0 = ss.initial_A;
            uint256 t0 = ss.initial_A_time;
            // Expressions in uint256 cannot have negative numbers, thus "if"
            if (A1 > A0) {
                return A0 + ((A1 - A0) * (block.timestamp - t0)) / (t1 - t0);
            } else {
                return A0 - ((A0 - A1) * (block.timestamp - t0)) / (t1 - t0);
            }
        } else {
            // when t1 == 0 or block.timestamp >= t1,
            // then it means the A parameter is already at its future value
            return A1;
        }
    }

    function _xp() internal view returns (uint256[] memory result) {
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        result = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            result[i] = (ss.RATES[i] * ss.balances[i]) / PRECISION;
        }
    }

    function _xp_mem(uint256[] memory _rates, uint256[] memory _balances) internal pure returns (uint256[] memory result) {
        result = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            result[i] = (_rates[i] * _balances[i]) / PRECISION;
        }
    }

    function _get_D(uint256[] memory xp, uint256 amp) internal pure returns (uint256) {
        uint256 S;
        for (uint256 i = 0; i < 2; i++) {
            S += xp[i];
        }
        if (S == 0) {
            return 0;
        }

        uint256 Dprev;
        uint256 D = S;
        uint256 Ann = amp * 2;
        for (uint256 i = 0; i < 255; i++) {
            uint256 D_P = D;
            for (uint256 j = 0; j < 2; j++) {
                D_P = (D_P * D) / (xp[j] * 2);
                // If division by 0, this will be borked: only withdrawal will work. And that is good
            }
            Dprev = D;
            D = ((Ann * S + D_P * 2) * D) / ((Ann - 1) * D + (2 + 1) * D_P);
            // Equality with the precision of 1
            if (D > Dprev) {
                if (D - Dprev <= 1) {
                    break;
                }
            } else if (Dprev - D <= 1) {
                break;
            }
        }
        return D;
    }

    function _get_D_mem(uint256[] memory _rates, uint256[] memory _balances, uint256 amp) internal pure returns (uint256) {
        return _get_D(_xp_mem(_rates, _balances), amp);
    }

    function _get_y(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[] memory xp_
    ) internal view returns (uint256) {
        // x in the input is converted to the same price/precision
        require(i != j && i < 2 && j < 2, "IllegalParameter");
        uint256 amp = _get_A();
        uint256 D = _get_D(xp_, amp);
        uint256 c = D;
        uint256 S_;
        uint256 Ann = amp * 2;

        uint256 _x;
        for (uint256 k = 0; k < 2; k++) {
            if (k == i) {
                _x = x;
            } else if (k != j) {
                _x = xp_[k];
            } else {
                continue;
            }
            S_ += _x;
            c = (c * D) / (_x * 2);
        }
        c = (c * D) / (Ann * 2);
        uint256 b = S_ + D / Ann; // - D
        uint256 y_prev;
        uint256 y = D;

        for (uint256 m = 0; m < 255; m++) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            // Equality with the precision of 1
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    break;
                }
            } else {
                if (y_prev - y <= 1) {
                    break;
                }
            }
        }
        return y;
    }

    function _get_y_D(
        uint256 A_,
        uint256 i,
        uint256[] memory xp,
        uint256 D
    ) internal pure returns (uint256) {
        /**
        Calculate x[i] if one reduces D from being calculated for xp to D

        Done by solving quadratic equation iteratively.
        x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
        x_1**2 + b*x_1 = c

        x_1 = (x_1**2 + c) / (2*x_1 + b)
        */
        // x in the input is converted to the same price/precision
 

        require(i < 2, "IllegalParameter");
        uint256 c = D;
        uint256 S_;
        uint256 Ann = A_ * 2;

        uint256 _x;
        for (uint256 k = 0; k < 2; k++) {
            if (k != i) {
                _x = xp[k];
            } else {
                continue;
            }
            S_ += _x;
            c = (c * D) / (_x * 2);
        }
        c = (c * D) / (Ann * 2);
        uint256 b = S_ + D / Ann;
        uint256 y_prev;
        uint256 y = D;

        for (uint256 k = 0; k < 255; k++) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            // Equality with the precision of 1
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    break;
                }
            } else {
                if (y_prev - y <= 1) {
                    break;
                }
            }
        }
        return y;
    }

    function _calc_withdraw_one_coin(uint256 _token_amount, uint256 i, uint256 tokenSupply) internal view returns (uint256, uint256) {
        // First, need to calculate
        // * Get current D
        // * Solve Eqn against y_i for D - _token_amount
        uint256 _fee;
        uint256[] memory precisions;
        uint256 amp;
        {
            StableSwapStorage storage ss = LibStableSwap.diamondStorage();

            amp = _get_A();
            _fee = (ss.fee * 2) / (4 * (2 - 1));
            precisions = ss.PRECISION_MUL;
        }

        uint256[] memory xp = _xp();

        uint256 D0 = _get_D(xp, amp);
        uint256 D1 = D0 - (_token_amount * D0) / tokenSupply;
        uint256[] memory xp_reduced = xp;

        uint256 new_y = _get_y_D(amp, i, xp, D1);
        uint256 dy_0 = (xp[i] - new_y) / precisions[i]; // w/o fees
 
        for (uint256 k = 0; k < 2; k++) {
            uint256 dx_expected;
            if (k == i) {
                dx_expected = (xp[k] * D1) / D0 - new_y;
            } else {
                dx_expected = xp[k] - (xp[k] * D1) / D0;
            }
            xp_reduced[k] -= (_fee * dx_expected) / FEE_DENOMINATOR;
        }
        uint256 dy = xp_reduced[i] - _get_y_D(amp, i, xp_reduced, D1);
        dy = (dy - 1) / precisions[i]; // Withdraw less to account for rounding errors

        return (dy, dy_0 - dy);
    }

    function addLiquidityWithMigrate(uint256[] memory amounts, uint256 min_mint_amount, uint256 migrate_amount) external returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        StableSwapStorage storage ss = LibStableSwap.diamondStorage();
        require(msg.sender == s.migrator, "Not called from migrator");
        uint256 amp = _get_A();

        uint256 D0;
        uint256[] memory old_balances = ss.balances;
        if (s.totalSupply > 0) {
            D0 = _get_D_mem(ss.RATES, old_balances, amp);
        }
        uint256[] memory new_balances = old_balances;
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = amounts[i];
            if (s.totalSupply == 0) {
                require(amount > 0, "Initial deposit requires all coins");
            }
            // Take coins from the sender
            if (amount  > 0) {
                IERC20(ss.coins[i]).safeTransferFrom(msg.sender, address(this), amount);
            }
            new_balances[i] += amount;
        }
        // Invariant after change
        uint256 D1 = _get_D_mem(ss.RATES, new_balances, amp);
        require(D1 > D0, "D1 mus be greater than D0");

        // We need to recalculate the invariant accounting for fees
        // to calculate fair user's share
        uint256 D2 = D1;
        uint256[] memory fees = new uint256[](2);
        if (s.totalSupply > 0) {
            uint256 _fee = (ss.fee * 2) / (4 * (2 - 1));
            // Only account for fees if we are not the first to deposit
                for (uint256 i = 0; i < 2; i++) {
                uint256 ideal_balance = (D1 * old_balances[i]) / D0;
                uint256 difference;
                if (ideal_balance > new_balances[i]) {
                    difference = ideal_balance - new_balances[i];
                } else {
                    difference = new_balances[i] - ideal_balance;
                }
                fees[i] = (_fee * difference) / FEE_DENOMINATOR;
                ss.balances[i] = new_balances[i] - ((fees[i] * ss.admin_fee) / FEE_DENOMINATOR);
                new_balances[i] -= fees[i];
            }
            D2 = _get_D_mem(ss.RATES, new_balances, amp);
        } else {
            ss.balances = new_balances;
        }

        // Calculate and Mint LP Token
        uint256 mint_amount;
        {
            if (s.totalSupply == 0) {
                mint_amount = migrate_amount;
            } else {
                mint_amount = (s.totalSupply * (D2 - D0)) / D0;
            }
            require(mint_amount >= min_mint_amount, "SlippageError");
            {
                s.totalSupply += mint_amount;
                unchecked {
                    // Overflow not possible: balance + amount is at most totalSupply + amount, which is checked above.
                    s.balances[msg.sender] += mint_amount;
                }
                emit Transfer(address(0), msg.sender, mint_amount);
            }
            emit AddLiquidity(msg.sender, amounts, fees, D1, s.totalSupply);
        }
        return mint_amount;
    }
}