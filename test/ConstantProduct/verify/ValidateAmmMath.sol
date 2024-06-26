// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ConstantProduct, GPv2Order, IERC20, IConditionalOrder} from "src/ConstantProduct.sol";
import {UniswapV2PriceOracle, IUniswapV2Pair} from "src/oracles/UniswapV2PriceOracle.sol";

import {ConstantProductTestHarness} from "../ConstantProductTestHarness.sol";

abstract contract ValidateAmmMath is ConstantProductTestHarness {
    IUniswapV2Pair pair = IUniswapV2Pair(makeAddr("pair for math verification"));

    function setUpAmmWithReserves(uint256 amountToken0, uint256 amountToken1) internal {
        vm.mockCall(address(pair), abi.encodeCall(IUniswapV2Pair.token0, ()), abi.encode(constantProduct.token0()));
        vm.mockCall(address(pair), abi.encodeCall(IUniswapV2Pair.token1, ()), abi.encode(constantProduct.token1()));
        // Reverts for everything else
        vm.mockCallRevert(address(pair), hex"", abi.encode("Called unexpected function on mock pair"));
        require(pair.token0() != pair.token1(), "Pair setup failed: should use distinct tokens");

        vm.mockCall(
            address(pair.token0()),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(constantProduct)),
            abi.encode(amountToken0)
        );
        vm.mockCall(
            address(pair.token1()),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(constantProduct)),
            abi.encode(amountToken1)
        );
    }

    function setUpOrderWithReserves(uint256 amountToken0, uint256 amountToken1)
        internal
        returns (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order)
    {
        setUpDefaultCommitment();
        setUpAmmWithReserves(amountToken0, amountToken1);
        order = getDefaultOrder();
        order.sellToken = IERC20(pair.token0());
        order.buyToken = IERC20(pair.token1());
        order.sellAmount = 0;
        order.buyAmount = 0;

        tradingParams = ConstantProduct.TradingParams(
            0, uniswapV2PriceOracle, abi.encode(abi.encode(UniswapV2PriceOracle.Data(pair))), order.appData
        );
    }

    // Note: if X is the reserve of the token that is taken from the AMM, and Y
    // the reserve of the token that is deposited into the AMM, then given any
    // in amount x you can compute the out amount for a constant-product AMM as:
    //         Y * x
    //   y = ---------
    //         X - x
    function getExpectedAmountIn(uint256[2] memory reserves, uint256 amountOut) internal pure returns (uint256) {
        uint256 poolIn = reserves[0];
        uint256 poolOut = reserves[1];
        return poolIn * amountOut / (poolOut - amountOut);
    }

    function testExactAmountsInOut() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolOut, poolIn);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        order.sellAmount = amountOut;
        order.buyAmount = amountIn;

        constantProduct.verify(tradingParams, order);

        // The next line is there so that we can see at a glance that the out
        // amount is reasonable given the in amount, since the math could be
        // hiding the fact that the AMM leads to bad orders.
        require(amountIn == 1 ether, "amount in was not updated");
    }

    function testVeryLargeBuyAmountDoesNotRevert() public {
        // If the buy amount is very high, the AMM should always be willing to
        // trade.
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolOut, poolIn);

        order.sellAmount = 1 ether;
        // Large enough compared to the sell amount, but not so large that it
        // causes overflow issues.
        order.buyAmount = type(uint128).max;

        constantProduct.verify(tradingParams, order);
    }

    function testVeryLowSellAmountDoesNotRevert() public {
        // If the buy amount is very low (that is, the sell amount is
        // comparatively high), the AMM should always be willing to trade.
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolOut, poolIn);

        order.sellAmount = 1;
        order.buyAmount = 1 ether;

        constantProduct.verify(tradingParams, order);
    }

    function testOneTooMuchOut() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolOut, poolIn);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        order.sellAmount = amountOut + 1;
        order.buyAmount = amountIn;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "received amount too low"));
        constantProduct.verify(tradingParams, order);
    }

    function testOneTooLittleIn() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolOut, poolIn);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        order.sellAmount = amountOut;
        order.buyAmount = amountIn - 1;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "received amount too low"));
        constantProduct.verify(tradingParams, order);
    }

    function testInvertInOutToken() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolIn, poolOut);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        (order.sellToken, order.buyToken) = (order.buyToken, order.sellToken);
        order.sellAmount = amountOut;
        order.buyAmount = amountIn;

        constantProduct.verify(tradingParams, order);
    }

    function testInvertedTokenVeryLargeBuyAmountDoesNotRevert() public {
        // If the buy amount is very high, the AMM should always be willing to
        // trade.
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolIn, poolOut);

        order.sellAmount = 1 ether;
        // Large enough compared to the sell amount, but not so large that it
        // causes overflow issues.
        order.buyAmount = type(uint128).max;

        constantProduct.verify(tradingParams, order);
    }

    function testInvertedTokenVeryLowSellAmountDoesNotRevert() public {
        // If the buy amount is very low (that is, the sell amount is
        // comparatively high), the AMM should always be willing to trade.
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolIn, poolOut);

        order.sellAmount = 1;
        order.buyAmount = 1 ether;

        constantProduct.verify(tradingParams, order);
    }

    function testInvertedTokenOneTooMuchOut() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolIn, poolOut);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        (order.sellToken, order.buyToken) = (order.buyToken, order.sellToken);
        order.sellAmount = amountOut + 1;
        order.buyAmount = amountIn;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "received amount too low"));
        constantProduct.verify(tradingParams, order);
    }

    function testInvertedTokensOneTooLittleIn() public {
        uint256 poolOut = 1100 ether;
        uint256 poolIn = 10 ether;
        (ConstantProduct.TradingParams memory tradingParams, GPv2Order.Data memory order) =
            setUpOrderWithReserves(poolIn, poolOut);

        uint256 amountOut = 100 ether;
        uint256 amountIn = getExpectedAmountIn([poolIn, poolOut], amountOut);
        (order.sellToken, order.buyToken) = (order.buyToken, order.sellToken);
        order.sellAmount = amountOut;
        order.buyAmount = amountIn - 1;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "received amount too low"));
        constantProduct.verify(tradingParams, order);
    }
}
