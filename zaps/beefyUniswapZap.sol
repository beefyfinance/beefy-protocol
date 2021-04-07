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

import 'https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/token/ERC20/SafeERC20.sol';
import 'https://github.com/Uniswap/uniswap-v3-core/blob/main/contracts/libraries/LowGasSafeMath.sol';

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
    using LowGasSafeMath for uint256;
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public immutable router;
    uint256 public constant minimumAmount = 1000;

    constructor(address _router) {
        router = IUniswapV2Router02(_router);
    }

    function beefIn (address beefyVault, uint tokenAmountOutMin, address tokenIn, uint tokenInAmount) external {
        require(tokenInAmount >= minimumAmount, 'Beefy: Insignificant input amount');
        require(IERC20(tokenIn).allowance(msg.sender, address(this)) >= tokenInAmount, 'Beefy: Input token is not approved');

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), tokenInAmount);

        _swapAndStake(beefyVault, tokenAmountOutMin, tokenIn);
    }

    function beefInETH (address beefyVault, uint tokenAmountOutMin) external payable {
        require(msg.value >= minimumAmount, 'Beefy: Insignificant input amount');

        IWETH(router.WETH()).deposit{value: msg.value}();

        _swapAndStake(beefyVault, tokenAmountOutMin, router.WETH());
    }

    function _swapAndStake(address beefyVault, uint tokenAmountOutMin, address tokenIn) private {
        IBeefyVault vault = IBeefyVault(beefyVault);
        IUniswapV2Pair pair = IUniswapV2Pair(vault.token());
        require(pair.factory() == router.factory(), 'Beefy: Incompatible liquidity pair factory');

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        require(reserveA > minimumAmount && reserveB > minimumAmount, 'Beefy: Liquidity pair reserves too low');

        bool isInputA = pair.token0() == tokenIn;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = isInputA ? pair.token1() : pair.token0();

        uint256 fullInvestment = IERC20(tokenIn).balanceOf(address(this));
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

        (,, uint256 amountLiquidity) = router
            .addLiquidity(path[0], path[1], fullInvestment.sub(swapAmounts[0]), swapAmounts[1], 1, 1, address(this), block.timestamp);

        _approveTokenIfNeeded(address(pair), address(vault));
        vault.deposit(amountLiquidity);

        IERC20 mooToken = IERC20(address(vault));
        mooToken.safeTransfer(msg.sender, mooToken.balanceOf(address(this)));
        _returnDust(path);
    }

    function _returnDust(address[] memory path) private {
        IERC20 tokenADust = IERC20(path[0]);
        uint256 tokenABalance = tokenADust.balanceOf(address(this));
        if (tokenABalance > 0) {
            tokenADust.safeTransfer(msg.sender, tokenABalance);
        }

        IERC20 tokenBDust = IERC20(path[1]);
        uint256 tokenBBalance = tokenBDust.balanceOf(address(this));
        if (tokenBBalance > 0) {
            tokenBDust.safeTransfer(msg.sender, tokenBBalance);
        }

        uint256 contractBalance = address(this).balance;
        if (contractBalance > 0) {
            msg.sender.transfer(contractBalance);
        }
    }

    function _getSwapAmount(uint256 investmentA, uint256 reserveA, uint256 reserveB) private view returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA / 2;
        uint256 swapExactQuote = router.quote(halfInvestment, reserveA, reserveB);
        uint256 swapOutputAmount = router.getAmountOut(halfInvestment, reserveA, reserveB);
        swapAmount = investmentA.sub(Babylonian.sqrt(halfInvestment * halfInvestment * swapOutputAmount / swapExactQuote));
        require(swapAmount > halfInvestment, 'swapInvestmentAmount should be greater than halfInvestment');
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

}
