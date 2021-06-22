// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "./HifiFlashSwapStorage.sol";
import "./interfaces/UniswapV2CalleeLike.sol";

abstract contract HifiFlashSwapInterface is
    HifiFlashSwapStorage, // no dependency
    UniswapV2CalleeLike // no dependency
{
    event FlashLiquidate(
        address indexed liquidator,
        address indexed borrower,
        address indexed hToken,
        uint256 flashBorrowedUsdcAmount,
        uint256 mintedHUsdcAmount,
        uint256 clutchedWbtcAmount,
        uint256 wbtcProfit
    );
}
