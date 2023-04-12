pragma solidity ^0.8.10;

interface IStableSwapFacet {

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

    function coin_length() external view returns (uint256);

    function PRECISION_MUL(uint256 i) external view returns (uint256);

    function RATES(uint256 i) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
    function fee() external view returns (uint256);
    function admin_fee() external view returns (uint256);
    function lp_token() external view returns (address);
    function A() external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function calc_token_amount(uint256[] memory amounts, bool deposit) external view returns (uint256);


    function get_dx(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
        
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function calc_token_amount(
        uint256[] memory amounts,
        bool deposit
    ) external view returns (uint256);

    function add_liquidity(
        uint256[] memory amounts,
        uint256 min_mint_amount
    ) external returns (uint256);

    function remove_liquidity(
        uint256 _amount,
        uint256[] memory min_amounts
    ) external returns (uint256[] memory);

    function remove_liquidity_imbalance(
        uint256[] memory amounts, 
        uint256 max_burn_amount
    ) external returns (uint256);

    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256);

    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external returns (uint256);

    function addLiquidityWithMigrate(
        uint256[] calldata amounts,
        uint256 min_mint_amount,
        uint256 migrateAmount
    ) external returns (uint256);

}