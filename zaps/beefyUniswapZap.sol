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
    function withdraw(uint256 wad) external;
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

    receive() external payable {
        assert(msg.sender == router.WETH());
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

    function beefOut (address beefyVault, uint withdrawAmount) external {
        (IBeefyVault vault, IUniswapV2Pair pair) = _getVaultPair(beefyVault);

        IERC20(beefyVault).safeTransferFrom(msg.sender, address(this), withdrawAmount);
        require(IERC20(beefyVault).balanceOf(address(this)) > 0, 'Debug: no vault tokens');
        vault.withdraw(withdrawAmount);
        require(IERC20(vault.token()).balanceOf(address(this)) > 0, 'Debug: no lp tokens');

        address WETH = router.WETH();
        if (pair.token0() != WETH && pair.token1() != WETH) {
            return _removeLiqudity(address(pair), msg.sender);
        }

        _removeLiqudity(address(pair), address(this));
        uint256 balanceWETH = IERC20(WETH).balanceOf(address(this));
        require(balanceWETH > 0, 'Beefy: there is no WETH');
        IWETH(WETH).withdraw(balanceWETH);

        address[] memory tokens = new address[](2);
        tokens[0] = pair.token0();
        tokens[1] = pair.token1();

        _returnAssets(tokens);
    }

    function _removeLiqudity(address pair, address to) private {
        IERC20(pair).safeTransfer(pair, IERC20(pair).balanceOf(address(this)));
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);

        require(amount0 >= minimumAmount, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amount1 >= minimumAmount, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    function _getVaultPair (address beefyVault) private returns (IBeefyVault vault, IUniswapV2Pair pair) {
        vault = IBeefyVault(beefyVault);
        pair = IUniswapV2Pair(vault.token());
        require(pair.factory() == router.factory(), 'Beefy: Incompatible liquidity pair factory');
    }

    function _swapAndStake(address beefyVault, uint tokenAmountOutMin, address tokenIn) private {
        (IBeefyVault vault, IUniswapV2Pair pair) = _getVaultPair(beefyVault);

        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        require(reserveA > minimumAmount && reserveB > minimumAmount, 'Beefy: Liquidity pair reserves too low');

        bool isInputA = pair.token0() == tokenIn;
        bool isInputB = pair.token1() == tokenIn;
        require(isInputA || isInputB, 'Beefy: Input token not present in liqudity pair');

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
        _returnAssets(path);
    }

    function _returnAssets(address[] memory tokens) private {
        IERC20 tokenADust = IERC20(tokens[0]);
        uint256 tokenABalance = tokenADust.balanceOf(address(this));
        if (tokenABalance > 0) {
            tokenADust.safeTransfer(msg.sender, tokenABalance);
        }

        IERC20 tokenBDust = IERC20(tokens[1]);
        uint256 tokenBBalance = tokenBDust.balanceOf(address(this));
        if (tokenBBalance > 0) {
            tokenBDust.safeTransfer(msg.sender, tokenBBalance);
        }

        uint256 contractBalance = address(this).balance;
        if (contractBalance > 0) {
            (bool success,) = msg.sender.call{value: contractBalance}(new bytes(0));
            require(success, 'Beefy: ETH transfer failed');
        }
    }

    function _getSwapAmount(uint256 investmentA, uint256 reserveA, uint256 reserveB) private view returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA / 2;
        uint256 nominator = router.getAmountOut(halfInvestment, reserveA, reserveB);
        uint256 denominator = router.quote(halfInvestment, reserveA.add(halfInvestment), reserveB.sub(nominator));
        swapAmount = investmentA.sub(Babylonian.sqrt(halfInvestment * halfInvestment * nominator / denominator));
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

}
