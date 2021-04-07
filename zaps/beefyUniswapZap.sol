// SPDX-License-Identifier: GPLv2

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// @author Wivern for Beefy.Finance
// @notice This contract adds liquidity to Uniswap V2 compatible liquidity pair pools and stake.

pragma solidity >=0.6.2;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/Babylonian.sol';
// import '@uniswap/v2-core/contracts/interfaces/IUniswapV2ERC20.sol';

import 'https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol';

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/token/ERC20/ERC20.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

interface IBeefyVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function token() external returns (address);
}

contract BeefyUniV2Zap {
    using SafeMath for uint256;

    // IUniswapV2Router02 public immutable router;
    // address public immutable WETH;
    // IWETH public immutable WETH = IWETH(0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd);
    IUniswapV2Router02 public immutable router = IUniswapV2Router02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);

    // constructor(address _WETH, address _router) {
    //     WETH = _WETH;
    //     router = IUniswapV2Router02(_router);
    // }

    function beefInETH (address beefyVault, uint tokenAmountOutMin) external payable {
        require(msg.value >= 10, 'Insignificant input amount');

        IBeefyVault vault = IBeefyVault(beefyVault);
        IUniswapV2Pair pair = IUniswapV2Pair(vault.token());
        require(pair.factory() == router.factory(), 'Incompatible liquidity pair factory');

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        require(reserveA > 0 && reserveB > 0, 'Liquidity pair reserves should be greater than 0');

        bool isInputA = pair.token0() == router.WETH();

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = isInputA ? pair.token1() : pair.token0();

        IWETH(router.WETH()).deposit{value: msg.value}();

        uint256 fullInvestment = msg.value;
        uint256 swapAmountIn;
        if (isInputA) {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveA, reserveB);
        } else {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveB, reserveA);
        }

        _approveTokenIfNeeded(path[0], address(router));
        _approveTokenIfNeeded(path[1], address(router));

        uint256[] memory swapAmounts = router
            .swapExactTokensForTokens(swapAmountIn, tokenAmountOutMin, path, address(this), block.timestamp);

        (uint amountLiquidityA, uint amountLiquidityB, uint amountLiquidity) = router
            .addLiquidity(path[0], path[1], fullInvestment.sub(swapAmounts[0]), swapAmounts[1], 1, 1, address(this), block.timestamp);

        IERC20 mooToken = IERC20(address(vault));
        _approveTokenIfNeeded(address(pair), address(vault));
        vault.deposit(amountLiquidity);
        mooToken.transfer(msg.sender, mooToken.balanceOf(address(this)));

        IERC20 tokenADust = IERC20(path[0]);
        uint256 tokenABalance = tokenADust.balanceOf(address(this));
        if (tokenABalance > 0) {
            tokenADust.transfer(msg.sender, tokenABalance);
        }

        IERC20 tokenBDust = IERC20(path[1]);
        uint256 tokenBBalance = tokenBDust.balanceOf(address(this));
        if (tokenBBalance > 0) {
            tokenBDust.transfer(msg.sender, tokenBBalance);
        }

        uint256 contractBalance = address(this).balance;
        if (contractBalance > 0) {
            msg.sender.transfer(contractBalance);
        }
    }

    function _getSwapAmount(uint256 investmentA, uint256 reserveA, uint256 reserveB) private returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA.div(2);
        uint256 swapExactQuote = router.quote(halfInvestment, reserveA, reserveB);
        uint256 swapOutputAmount = router.getAmountOut(halfInvestment, reserveA, reserveB);
        swapAmount = investmentA.sub(Babylonian.sqrt(halfInvestment * halfInvestment * swapOutputAmount / swapExactQuote));
        require(swapAmount > halfInvestment, 'swapInvestmentAmount should be greater than halfInvestment');
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), address(spender)) == 0) {
            IERC20(token).approve(address(spender), uint256(~0));
        }
    }

}
