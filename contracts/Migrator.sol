// SPDX-License-Identifier: MIT

pragma solidity 0.5.6;

import '@openzeppelin/contracts/math/SafeMath.sol';
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IKlayswapExchange.sol';
import './interfaces/IWKLAY.sol';

contract Migrator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;


    address public chef;
    address public oldFactory;
    IUniswapV2Factory public factory;
    uint256 public notBeforeBlock;
    uint256 public desiredLiquidity = uint256(-1);
    address public WKLAY;

    constructor(
        address chef_,
        address oldFactory_,
        IUniswapV2Factory factory_,
        uint256 notBeforeBlock_,
        address WKLAY_
    ) public {
        chef = chef_;
        oldFactory = oldFactory_;
        factory = factory_;
        notBeforeBlock = notBeforeBlock_;
        WKLAY = WKLAY_;
    }

    function() external payable {
        require(IKlayswapExchange(msg.sender).factory() == oldFactory, 'not from old factory');
    }

    function migrate(IKlayswapExchange oldLp) public returns (IUniswapV2Pair) {
        require(msg.sender == chef, 'not from master chef');
        require(block.number >= notBeforeBlock, 'too early to migrate');
        require(oldLp.factory() == oldFactory, 'not from old factory');

        address tokenA = oldLp.tokenA();
        address tokenB = oldLp.tokenB();
        IUniswapV2Pair newLp = IUniswapV2Pair(
            factory.getPair(
                tokenA == address(0) ? WKLAY : tokenA,
                tokenB == address(0) ? WKLAY : tokenB
            )
        );
        if (newLp == IUniswapV2Pair(address(0))) {
            uint8 decimals = oldLp.decimals();
            newLp = IUniswapV2Pair(
                factory.createPair(
                    tokenA == address(0) ? WKLAY : tokenA,
                    tokenB == address(0) ? WKLAY : tokenB,
                    decimals
                )
            );
        }
        uint256 lp = oldLp.balanceOf(msg.sender);
        if (lp == 0) return newLp;
        desiredLiquidity = lp;
        IERC20(address(oldLp)).safeTransferFrom(msg.sender, address(this), lp);

        uint256 beforeBalanceA = tokenA == address(0)
            ? address(this).balance
            : IERC20(tokenA).balanceOf(address(this));
        uint256 beforeBalanceB = tokenB == address(0)
            ? address(this).balance
            : IERC20(tokenB).balanceOf(address(this));
        oldLp.removeLiquidity(lp);
        uint256 depositBalanceA = tokenA == address(0)
            ? address(this).balance.sub(beforeBalanceA)
            : IERC20(tokenA).balanceOf(address(this)).sub(beforeBalanceA);
        uint256 depositBalanceB = tokenB == address(0)
            ? address(this).balance.sub(beforeBalanceB)
            : IERC20(tokenB).balanceOf(address(this)).sub(beforeBalanceB);
        if (tokenA == address(0) || tokenB == address(0)) {
            uint256 wklayBeforeBalance = IERC20(WKLAY).balanceOf(address(this));
            uint256 depositBalance = tokenA == address(0)
                ? depositBalanceA
                : depositBalanceB;
            IWKLAY(WKLAY).deposit.value(depositBalance)();
            assert(
                IERC20(WKLAY).balanceOf(address(this)) ==
                    wklayBeforeBalance.add(depositBalance)
            );
            tokenA == address(0) ? tokenA = WKLAY : tokenB = WKLAY;
        }
        IERC20(tokenA).safeTransfer(address(newLp), depositBalanceA);
        IERC20(tokenB).safeTransfer(address(newLp), depositBalanceB);
        newLp.mint(msg.sender);
        desiredLiquidity = uint256(-1);
        return newLp;
    }
}
