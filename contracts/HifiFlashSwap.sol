// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity >=0.8.0;

import "@paulrberg/contracts/access/Admin.sol";
import "@paulrberg/contracts/token/erc20/IErc20.sol";
import "@hifi/protocol/contracts/core/balanceSheet/IBalanceSheetV1.sol";
import "@hifi/protocol/contracts/core/hToken/IHToken.sol";

import "./HifiFlashSwapInterface.sol";
import "./interfaces/UniswapV2PairLike.sol";

/// @title HifiFlashSwap
/// @author Hifi
contract HifiFlashSwap is
    HifiFlashSwapInterface, // one dependency
    Admin // two dependencies
{
    constructor(address balanceSheet_, address[] memory pairs_) Admin() {
        balanceSheet = IBalanceSheetV1(balanceSheet_);
        for (uint256 i = 0; i < pairs_.length; i++) {
            pairs[pairs_[i]] = UniswapV2PairLike(pairs_[i]);
        }
        usdc = IErc20(pairs[pairs_[0]].token1());
    }

    /// @dev Calculate the amount of collateral that has to be repaid to Uniswap. The formula applied is:
    ///
    ///              (collateralReserves * usdcAmount) * 1000
    /// repayment = ------------------------------------
    ///              (usdcReserves - usdcAmount) * 997
    ///
    /// See "getAmountIn" and "getAmountOut" in UniswapV2Library.sol. Flash swaps that are repaid via
    /// the corresponding pair token is akin to a normal swap, so the 0.3% LP fee applies.
    function getRepayCollateralAmount(UniswapV2PairLike pair, uint256 usdcAmount) public view returns (uint256) {
        (uint112 collateralReserves, uint112 usdcReserves, ) = pair.getReserves();

        // Note that we don't need CarefulMath because the UniswapV2Pair.sol contract performs sanity
        // checks on "collateralAmount" and "usdcAmount" before calling the current contract.
        uint256 numerator = collateralReserves * usdcAmount * 1000;
        uint256 denominator = (usdcReserves - usdcAmount) * 997;
        uint256 collateralRepaymentAmount = numerator / denominator + 1;

        return collateralRepaymentAmount;
    }

    /// @dev Called by the UniswapV2Pair contract.
    function uniswapV2Call(
        address sender,
        uint256 collateralAmount,
        uint256 usdcAmount,
        bytes calldata data
    ) external override {
        require(address(pairs[msg.sender]) != address(0), "ERR_UNISWAP_V2_CALL_NOT_AUTHORIZED");
        require(collateralAmount == 0, "ERR_COLLATERAL_AMOUNT_ZERO");

        // Unpack the ABI encoded data passed by the UniswapV2Pair contract.
        (address borrower, IHToken hToken, uint256 minProfit, IErc20 collateral) = abi.decode(
            data,
            (address, IHToken, uint256, IErc20)
        );

        // Mint hUSDC and liquidate the borrower.
        uint256 mintedHUsdcAmount = mintHUsdc(hToken, usdcAmount);
        uint256 clutchedCollateralAmount = liquidateBorrow(borrower, hToken, mintedHUsdcAmount, collateral);

        // Calculate the amount of collateral required.
        uint256 repayCollateralAmount = getRepayCollateralAmount(pairs[msg.sender], usdcAmount);
        require(clutchedCollateralAmount > repayCollateralAmount + minProfit, "ERR_INSUFFICIENT_PROFIT");

        // Pay back the loan.
        require(collateral.transfer(address(pairs[msg.sender]), repayCollateralAmount), "ERR_COLLATERAL_TRANSFER");

        // Reap the profit.
        uint256 profit = clutchedCollateralAmount - repayCollateralAmount;
        collateral.transfer(sender, profit);

        emit FlashLiquidate(
            sender,
            borrower,
            address(hToken),
            usdcAmount,
            mintedHUsdcAmount,
            clutchedCollateralAmount,
            profit
        );
    }

    /// @dev Supply the USDC to the hToken and mint hUSDC.
    function mintHUsdc(IHToken hToken, uint256 usdcAmount) internal returns (uint256) {
        // Allow the hToken to spend USDC if allowance not enough.
        uint256 allowance = usdc.allowance(address(this), address(hToken));
        if (allowance < usdcAmount) {
            usdc.approve(address(hToken), type(uint256).max);
        }

        uint256 oldHTokenBalance = hToken.balanceOf(address(this));
        hToken.supplyUnderlying(usdcAmount);
        uint256 newHTokenBalance = hToken.balanceOf(address(this));
        uint256 mintedHUsdcAmount = newHTokenBalance - oldHTokenBalance;
        return mintedHUsdcAmount;
    }

    /// @dev Liquidate the borrower by transferring the USDC to the BalanceSheet. In doing this,
    /// the liquidator receives collateral at a discount.
    function liquidateBorrow(
        address borrower,
        IHToken hToken,
        uint256 mintedHUsdcAmount,
        IErc20 collateral
    ) internal returns (uint256) {
        uint256 oldCollateralBalance = collateral.balanceOf(address(this));
        balanceSheet.liquidateBorrow(borrower, hToken, mintedHUsdcAmount, collateral);
        uint256 newCollateralBalance = collateral.balanceOf(address(this));
        uint256 clutchedCollateralAmount = newCollateralBalance - oldCollateralBalance;
        return clutchedCollateralAmount;
    }
}
