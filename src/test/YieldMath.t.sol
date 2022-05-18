// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.13; /*
  __     ___      _     _
  \ \   / (_)    | |   | | ████████╗███████╗███████╗████████╗███████╗
   \ \_/ / _  ___| | __| | ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝██╔════╝
    \   / | |/ _ \ |/ _` |    ██║   █████╗  ███████╗   ██║   ███████╗
     | |  | |  __/ | (_| |    ██║   ██╔══╝  ╚════██║   ██║   ╚════██║
     |_|  |_|\___|_|\__,_|    ██║   ███████╗███████║   ██║   ███████║
      yieldprotocol.com       ╚═╝   ╚══════╝╚══════╝   ╚═╝   ╚══════╝
*/

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exp64x64} from "./../Exp64x64.sol";
import {YieldMath} from "./../YieldMath.sol";
import {Math64x64} from "./../Math64x64.sol";

import "./helpers.sol";

/**TESTS

Links to Desmos for each formula can be found at:
https://docs.google.com/spreadsheets/d/14K_McZhlgSXQfi6nFGwDvDh4BmOu6_Hczi_sFreFfOE/

Tests grouped by function:
1. function fyTokenOutForSharesIn
2. function sharesInForFYTokenOut
3. function sharesOutForFYTokenIn
4. function fyTokenInForSharesOut

Each function has the following tests:
__overReserves  - test that the fn reverts if amounts are > reserves
__reverts       - try to hit each of the require statements within each function
__basecases     - test 5 scenarios comparing results to Desmos
__mirror        - FUZZ test the tokensOut of one fn can be piped to the tokensIn of the mirror fn
__noFees1       - FUZZ test the inverse of one fn reverts change from original fn -- assuming no fees
__noFees2       - FUZZ test the inverse of one fn reverts change from original fn -- assuming no fees
__isCatMaturity - FUZZ test that the value of the fn approaches C at maturity

Test name prefixe definitions:
testFail_          - Unit tests that pass if the test reverts
testUnit_          - Unit tests for common edge cases
testFuzz_          - Property based fuzz tests

All 4 trading functions were tested against eachother as follows:

                       ┌───────────────────────┬───────────────────────┬───────────────────────┬──────────────────────┐
                       │ fyTokenOutForSharesIn │ sharesInForFYTokenOut │ sharesOutForFYTokenIn │ fyTokenInForSharesOut│
┌──────────────────────┼───────────────────────┼───────────────────────┼───────────────────────┼──────────────────────┤
│                      │                       │                       │                       │                      │
│fyTokenOutForSharesIn │          X            │ fyTokenOutForSharesIn │ fyTokenOutForSharesIn │ fyTokenOutForSharesIn│
│                      │                       │ __mirror              │ __noFees1             │ __noFees2            │
├──────────────────────┼───────────────────────┼───────────────────────┼───────────────────────┼──────────────────────┤
│                      │                       │                       │                       │                      │
│sharesInForFYTokenOut │ sharesInForFYTokenOut │           X           │ sharesInForFYTokenOut │ sharesInForFYTokenOut│
│                      │ __mirror              │                       │ __noFees2             │ __noFees1            │
├──────────────────────┼───────────────────────┼───────────────────────┼───────────────────────┼──────────────────────┤
│                      │                       │                       │                       │                      │
│sharesOutForFYTokenIn │ sharesOutForFYTokenIn │ sharesOutForFYTokenIn │           X           │ sharesOutForFYTokenIn│
│                      │ __noFees1             │ __noFees2             │                       │ __mirror             │
├──────────────────────┼───────────────────────┼───────────────────────┼───────────────────────┼──────────────────────┤
│                      │                       │                       │                       │                      │
│fyTokenInForSharesOut │ fyTokenInForSharesOut │ fyTokenInForSharesOut │ fyTokenInForSharesOut │          X           │
│                      │ __noFees2             │ __noFees1             │ __mirror              │                      │
└──────────────────────┴───────────────────────┴───────────────────────┴───────────────────────┴──────────────────────┘

**********************************************************************************************************************/

contract YieldMathTest is Test {
    using Exp64x64 for uint128;
    using Math64x64 for int128;
    using Math64x64 for int256;
    using Math64x64 for uint128;
    using Math64x64 for uint256;

    uint128 public constant fyTokenReserves = uint128(1500000 * 1e18); // Y
    uint128 public constant sharesReserves = uint128(1100000 * 1e18); // Z

    // The DESMOS uses 0.1 second increments, so we use them here in the tests for easy comparison.  In the deployed
    // contract we use seconds.
    uint128 public constant timeTillMaturity = uint128(90 * 24 * 60 * 60 * 10); // T

    int128 immutable k;

    uint256 public constant gNumerator = 95;
    uint256 public constant gDenominator = 100;
    int128 public g1; // g to use when selling shares to pool
    int128 public g2; // g to use when selling fyTokens to pool

    uint256 public constant cNumerator = 11;
    uint256 public constant cDenominator = 10;
    int128 public c;

    uint256 public constant muNumerator = 105;
    uint256 public constant muDenominator = 100;
    int128 public mu;

    constructor() {
        // The Desmos formulas use this * 10 at the end for tenths of a second.  Pool.sol does not.
        uint256 invK = 25 * 365 * 24 * 60 * 60 * 10;
        k = uint256(1).fromUInt().div(invK.fromUInt());

        g1 = gNumerator.fromUInt().div(gDenominator.fromUInt());
        g2 = gDenominator.fromUInt().div(gNumerator.fromUInt());
        c = cNumerator.fromUInt().div(cDenominator.fromUInt());
        mu = muNumerator.fromUInt().div(muDenominator.fromUInt());
    }

    function isClose(
        uint256 result,
        uint256 expectedResult,
        uint256 maxDiff
    ) public pure {
        if (expectedResult > result) {
            require((expectedResult - result) <= maxDiff);
        } else {
            require((result - expectedResult) <= maxDiff);
        }
    }

    /* 1. function fyTokenOutForSharesIn
     ***************************************************************/

    function testFail_fyTokenOutForSharesIn__overReserves() public view {
        // This would require more fytoken than are available, so it should revert.
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            1_380_000 * 1e18, // x or ΔZ Number obtained from looking at Desmos chart.
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;
    }

    function testUnit_fyTokenOutForSharesIn__reverts() public {
        // Try to hit all require statements within the function
        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            0,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            0
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nsr)"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            type(int128).max
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (za)"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            type(int128).max,
            0x10000000000000000
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nsi)"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            type(uint128).max,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rounding error"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            100000,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;
        // NOTE: could not hit "YieldMath: > fyToken reserves" <- possibly redundant
    }

    function testUnit_fyTokenOutForSharesIn__baseCases() public view {
        // should match Desmos for selected inputs
        uint128[6] memory sharesAmounts = [
            uint128(50_000 * 1e18),
            uint128(100_000 * 1e18),
            uint128(200_000 * 1e18),
            uint128(500_000 * 1e18),
            uint128(900_000 * 1e18),
            uint128(1_379_104 * 1e18)
        ];
        uint128[6] memory expectedResults = [
            uint128(55_113),
            uint128(110_185),
            uint128(220_202),
            uint128(549_235),
            uint128(985_292),
            uint128(1_500_000)
        ];
        uint128 result;
        for (uint256 idx; idx < sharesAmounts.length; idx++) {
            result =
                YieldMath.fyTokenOutForSharesIn(
                    sharesReserves,
                    fyTokenReserves,
                    sharesAmounts[idx], // x or ΔZ
                    timeTillMaturity,
                    k,
                    g1,
                    c,
                    mu
                ) /
                1e18;

            isClose(result, expectedResults[idx], 2);
        }
    }

    function testFuzz_fyTokenOutForSharesIn__mirror(uint128 sharesAmount) public {
        sharesAmount = uint128(bound(sharesAmount, 10000000000000000000, 1_379_000 * 1e18)); // max per desmos
        uint128 result;
        result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        uint128 resultShares = YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            result,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );

        require(resultShares / 1e18 == sharesAmount / 1e18);
    }

    function testFuzz_fyTokenOutForSharesIn__noFees1(uint128 sharesAmount) public {
        sharesAmount = uint128(bound(sharesAmount, 10000000000000000000, 1_379_000 * 1e18));
        uint128 result;
        result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.sharesOutForFYTokenIn(
            sharesReserves + sharesAmount,
            fyTokenReserves - result,
            result,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        require(result2 / 1e18 == sharesAmount / 1e18);
    }

    function testFuzz_fyTokenOutForSharesIn__noFees2(uint128 sharesAmount) public {
        sharesAmount = uint128(bound(sharesAmount, 10000000000000000000, 1_379_000 * 1e18));
        uint128 result;
        result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.fyTokenInForSharesOut(
            sharesReserves + sharesAmount,
            fyTokenReserves - result,
            sharesAmount,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        require(result / 1e18 == result2 / 1e18);
    }

    function testFuzz_fyTokenOutForSharesIn__isCatMaturity(uint128 sharesAmount) public {
        // At maturity the fytoken price will be close to c
        sharesAmount = uint128(bound(sharesAmount, 1000000000000000000, 1_370_000 * 1e18));
        uint128 result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            0,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        ) / 1e18;

        uint256 cPrice = ((cNumerator * sharesAmount) / cDenominator) / 1e18;

        isClose(result, cPrice, 2);
    }

    function testFuzz_fyTokenOutForSharesIn_farFromMaturity(uint128 sharesAmount) public {
        // asserts that when time to maturity is approaching 100% the result is the same as UniV2 style constant product amm
        sharesAmount = uint128(bound(sharesAmount, 1000000000000000000, 1_379_000 * 1e18));
        uint128 result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            25 * 365 * 24 * 60 * 60 * 10 - 10,
            k,
            int128(YieldMath.ONE), // set fees to 0
            int128(YieldMath.ONE), // set c to 1
            int128(YieldMath.ONE) //  set mu to 1
        );
        uint256 oldK = uint256(fyTokenReserves) * uint256(sharesReserves);

        uint256 newSharesReserves = sharesReserves + sharesAmount;
        uint256 newFyTokenReserves = oldK / newSharesReserves;
        uint256 ammFyOut = fyTokenReserves - newFyTokenReserves;

        console.log("ammFyOut", ammFyOut);
        console.log("result", result);
        isClose(ammFyOut / 1e18, result / 1e18, 1000);
    }

    // // function testUnit_fyTokenOutForSharesIn__increaseG(uint128 amount) public {
    // function testUnit_fyTokenOutForSharesIn__increaseG() public {
    //     uint128 amount = uint128(969274532731510217051237);
    //     // amount = uint128(bound(amount, 10000000000000000000, 1_379_000 * 1e18)); // max per desmos
    //     uint128 result1 = YieldMath.fyTokenOutForSharesIn(
    //         sharesReserves,
    //         fyTokenReserves,
    //         amount,
    //         timeTillMaturity,
    //         k,
    //         g1,
    //         c,
    //         mu
    //     ) / 1e18;

    //     int128 bumpedG = uint256(975).fromUInt().div((10 * gDenominator).fromUInt());
    //     uint128 result2 = YieldMath.fyTokenOutForSharesIn(
    //         sharesReserves,
    //         fyTokenReserves,
    //         amount,
    //         timeTillMaturity,
    //         k,
    //         bumpedG,
    //         c,
    //         mu
    //     ) / 1e18;
    //     console.log("+ + file: YieldMath.t.sol + line 400 + testUnit_fyTokenOutForSharesIn__increaseG + result1", result1);
    //     console.log("+ + file: YieldMath.t.sol + line 400 + testUnit_fyTokenOutForSharesIn__increaseG + result2", result2);
    //     require(result2 >= result1);
    // }

    /* 2. function sharesInForFYTokenOut
     ***************************************************************/

    function testFail_sharesInForFYTokenOut__overReserves() public {
        // Per desmos, this would require more fytoken than are available, so it should revert.
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            1_501_000, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rounding error"));
        YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            100000,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;

        // NOTE: could not hit "YieldMath: > fyToken reserves" <- possibly redundant
    }

    function testUnit_sharesInForFYTokenOut__reverts() public {
        // Try to hit all require statements within the function
        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            0,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            0
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nsr)"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            type(int128).max
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (za)"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            type(int128).max,
            0x10000000000000000
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate underflow"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            type(uint128).max,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (zyy)"));
        YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            100000,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;
    }

    function testUnit_sharesInForFYTokenOut__baseCases() public view {
        // should match Desmos for selected inputs
        uint128[5] memory fyTokenAmounts = [
            uint128(50000 * 1e18),
            uint128(100_000 * 1e18),
            uint128(200_000 * 1e18),
            uint128(900_000 * 1e18),
            uint128(1_500_000 * 1e18)
        ];
        uint128[5] memory expectedResults = [
            uint128(45359),
            uint128(90_749),
            uint128(181_625),
            uint128(821_505),
            uint128(1_379_104)
        ];
        uint128 result;
        for (uint256 idx; idx < fyTokenAmounts.length; idx++) {
            result =
                YieldMath.sharesInForFYTokenOut(
                    sharesReserves,
                    fyTokenReserves,
                    fyTokenAmounts[idx], // x or ΔZ
                    timeTillMaturity,
                    k,
                    g1,
                    c,
                    mu
                ) /
                1e18;

            isClose(result, expectedResults[idx], 2);
        }
    }

    function testFuzz_sharesInForFYTokenOut__mirror(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_379_000 * 1e18)); // max per desmos
        uint128 result = YieldMath.fyTokenOutForSharesIn(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        uint128 resultFYTokens = YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            result,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        isClose(resultFYTokens / 1e18, fyTokenAmount / 1e18, 2);
    }

    function testFuzz_sharesInForFYTokenOut__noFees1(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_379_000 * 1e18));
        uint128 result;
        result = YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.fyTokenInForSharesOut(
            sharesReserves + result,
            fyTokenReserves - fyTokenAmount,
            result,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        isClose(result2 / 1e18, fyTokenAmount / 1e18, 2);
    }

    function testFuzz_sharesInForFYTokenOut__noFees2(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_379_000 * 1e18));
        uint128 result;
        result = YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.sharesOutForFYTokenIn(
            sharesReserves + result,
            fyTokenReserves - fyTokenAmount,
            fyTokenAmount,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        require(result / 1e18 == result2 / 1e18);
    }

    function testFuzz_sharesInForFYTokenOut__isCatMaturity(uint128 fyTokenAmount) public {
        // At maturity the fytoken price will be close to c
        fyTokenAmount = uint128(bound(fyTokenAmount, 1000000000000000000, 1_370_000 * 1e18));
        uint128 result = YieldMath.sharesInForFYTokenOut(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            0,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        uint256 cPrice = (cNumerator * result) / cDenominator;

        isClose(fyTokenAmount / 1e18, cPrice / 1e18, 2);
    }

    // NOTE: testFuzz_sharesInForFYTokenOut_farFromMaturity cannot be implemented because the size of
    // time to maturity creates an overflow in the final step of the function.

    /* 3. function sharesOutForFYTokenIn
     ***************************************************************/

    function testFail_sharesOutForFYTokenIn__overReserves() public view {
        // should match Desmos for selected inputs
        YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            1_240_000 * 1e18, // x or ΔZ  adjusted up from desmos to account for normalization
            timeTillMaturity,
            k,
            g2,
            c,
            mu
        ) / 1e18;
    }

    function testUnit_sharesOutForFYTokenIn__reverts() public {
        // Try to hit all require statements within the function

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            0,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            0
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nsr)"));
        YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            type(int128).max
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (za)"));
        YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            type(int128).max,
            0x10000000000000000
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (yxa)"));
        YieldMath.sharesOutForFYTokenIn(50000, fyTokenReserves, 1_500_000 * 1e18, timeTillMaturity, k, g1, c, mu) /
            1e18;

        // NOTE: could not hit "YieldMath: Rate underflow" <- possibly redundant
    }

    function testUnit_sharesOutForFYTokenIn__baseCases() public view {
        // should match Desmos for selected inputs
        uint128[5] memory fyTokenAmounts = [
            uint128(25000 * 1e18),
            uint128(50_000 * 1e18),
            uint128(100_000 * 1e18),
            uint128(200_000 * 1e18),
            uint128(500_000 * 10**18)
        ];
        uint128[5] memory expectedResults = [
            uint128(22_661),
            uint128(45_313),
            uint128(90_592),
            uint128(181_041),
            uint128(451_473)
        ];
        uint128 result;
        for (uint256 idx; idx < fyTokenAmounts.length; idx++) {
            result =
                YieldMath.sharesOutForFYTokenIn(
                    sharesReserves,
                    fyTokenReserves,
                    fyTokenAmounts[idx], // x or ΔZ
                    timeTillMaturity,
                    k,
                    g2,
                    c,
                    mu
                ) /
                1e18;

            isClose(result, expectedResults[idx], 2);
        }
    }

    function testFuzz_sharesOutForFYTokenIn__mirror(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_100_000 * 1e18)); // max per desmos
        // should match Desmos for selected inputs
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        uint128 resultFYTokens = YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            result,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        isClose(resultFYTokens / 1e18, fyTokenAmount / 1e18, 2);
    }

    function testFuzz_sharesOutForFYTokenIn__noFees1(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_100_000 * 1e18)); // max per desmos

        uint128 result = YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.fyTokenOutForSharesIn(
            sharesReserves - result,
            fyTokenReserves + fyTokenAmount,
            result,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        require(result2 / 1e18 == fyTokenAmount / 1e18);
    }

    function testFuzz_sharesOutForFYTokenIn__noFees2(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_100_000 * 1e18)); // max per desmos

        uint128 result = YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.sharesInForFYTokenOut(
            sharesReserves - result,
            fyTokenReserves + fyTokenAmount,
            fyTokenAmount,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        require(result / 1e18 == result2 / 1e18);
    }

    function testFuzz_sharesOutForFYTokenIn__isCatMaturity(uint128 fyTokenAmount) public {
        // At maturity the fytoken price will be close to c
        fyTokenAmount = uint128(bound(fyTokenAmount, 1000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            0,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        uint256 cPrice = (cNumerator * result) / cDenominator;

        require(fyTokenAmount / 1e18 == cPrice / 1e18);
    }

    // NOTE: testFuzz_sharesOutForFYTokenIn_farFromMaturity cannot be implemented because the size of
    // time to maturity creates an overflow in the final step of the function.

    /* 4. function fyTokenInForSharesOut
     *
     ***************************************************************/
    function testFail_fyTokenInForSharesOut__overReserves() public view {
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_101_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g2,
            c,
            mu
        ) / 1e18;
    }

    function testUnit_fyTokenInForSharesOut__reverts() public {
        // Try to hit all require statements within the function

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            0,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: c and mu must be positive"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            0
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nsr)"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            type(int128).max
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (za)"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            type(int128).max,
            0x10000000000000000
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rate overflow (nso)"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            type(uint128).max,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Too many shares in"));
        YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            1_500_000 * 1e18,
            timeTillMaturity,
            k,
            g1,
            1e12,
            1
        ) / 1e18;

        vm.expectRevert(bytes("YieldMath: Rounding error"));
        YieldMath.fyTokenInForSharesOut(sharesReserves, 100000 * 1e18, 1_500 * 1e18, timeTillMaturity, k, g1, 1, 1) /
            1e18;

        // NOTE: could not hit "YieldMath: > fyToken reserves" <- possibly redundant
    }

    function testUnit_fyTokenInForSharesOut__baseCases() public view {
        // should match Desmos for selected inputs
        uint128[6] memory sharesAmounts = [
            uint128(50000 * 1e18),
            uint128(100_000 * 1e18),
            uint128(200_000 * 1e18),
            uint128(300_000 * 1e18),
            uint128(500_000 * 1e18),
            uint128(950_000 * 1e18)
        ];
        uint128[6] memory expectedResults = [
            uint128(55_173),
            uint128(110_393),
            uint128(220_981),
            uint128(331_770),
            uint128(554_008),
            uint128(1_058_525)
        ];
        uint128 result;
        for (uint256 idx; idx < sharesAmounts.length; idx++) {
            result =
                YieldMath.fyTokenInForSharesOut(
                    sharesReserves,
                    fyTokenReserves,
                    sharesAmounts[idx], // x or ΔZ
                    timeTillMaturity,
                    k,
                    g2,
                    c,
                    mu
                ) /
                1e18;

            isClose(result, expectedResults[idx], 2);
        }
    }

    function testFuzz_fyTokenInForSharesOut__mirror(uint128 fyTokenAmount) public {
        fyTokenAmount = uint128(bound(fyTokenAmount, 10000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            fyTokenAmount, // x or ΔZ
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        uint128 resultFYTokens = YieldMath.sharesOutForFYTokenIn(
            sharesReserves,
            fyTokenReserves,
            result,
            timeTillMaturity,
            k,
            g1,
            c,
            mu
        );
        isClose(resultFYTokens / 1e18, fyTokenAmount / 1e18, 2);
    }

    function testFuzz_fyTokenInForSharesOut__noFees1(uint128 sharesAmount) public {
        sharesAmount = uint128(bound(sharesAmount, 10000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        uint128 result2 = YieldMath.sharesInForFYTokenOut(
            sharesReserves - sharesAmount,
            fyTokenReserves + result,
            result,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        isClose(result2 / 1e18, sharesAmount / 1e18, 2);
    }

    function testFuzz_fyTokenInForSharesOut__noFees2(uint128 sharesAmount) public {
        sharesAmount = uint128(bound(sharesAmount, 10000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        console.log("+ + file: YieldMath.t.sol + line 1060 + testUnit_fyTokenInForSharesOut__noFees2 + result", result);
        uint128 result2 = YieldMath.fyTokenOutForSharesIn(
            sharesReserves - sharesAmount,
            fyTokenReserves + result,
            sharesAmount,
            timeTillMaturity,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );
        console.log(
            "+ + file: YieldMath.t.sol + line 1071 + testUnit_fyTokenInForSharesOut__noFees2 + result2",
            result2
        );
        require(result2 / 1e18 == result / 1e18);
    }

    function testFuzz_fyTokenInForSharesOut__isCatMaturity(uint128 sharesAmount) public {
        // At maturity the fytoken price will be close to c
        sharesAmount = uint128(bound(sharesAmount, 1000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            0,
            k,
            int128(YieldMath.ONE),
            c,
            mu
        );

        uint256 cPrice = (cNumerator * sharesAmount) / cDenominator;
        require(result / 1e18 == cPrice / 1e18);
    }

    function testFuzz_fyTokenInForSharesOut_farFromMaturity(uint128 sharesAmount) public {
        // asserts that when time to maturity is approaching 100% the result is the same as UniV2 style constant product amm
        sharesAmount = uint128(bound(sharesAmount, 1000000000000000000, 1_100_000 * 1e18));
        uint128 result = YieldMath.fyTokenInForSharesOut(
            sharesReserves,
            fyTokenReserves,
            sharesAmount, // x or ΔZ
            25 * 365 * 24 * 60 * 60 * 10 - 10,
            k,
            int128(YieldMath.ONE), // set fees to 0
            int128(YieldMath.ONE), // set c to 1
            int128(YieldMath.ONE) //  set mu to 1
        );
        uint256 oldK = uint256(fyTokenReserves) * uint256(sharesReserves);

        uint256 newSharesReserves = sharesReserves - sharesAmount;
        uint256 newFyTokenReserves = oldK / newSharesReserves;
        uint256 ammFyIn = newFyTokenReserves - fyTokenReserves;

        console.log("ammFyIn", ammFyIn / 1e18);
        console.log("result", result / 1e18);
        isClose(ammFyIn / 1e18, result / 1e18, 3000);
    }


}
