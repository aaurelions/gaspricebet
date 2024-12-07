// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GasPriceBet} from "../src/GasPriceBet.sol";

contract GasPriceBetTest is Test {
    GasPriceBet public gasPriceBet;

    function setUp() public {
        gasPriceBet = new GasPriceBet(address(0));
    }
}
