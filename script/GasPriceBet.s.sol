// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {GasPriceBet} from "../src/GasPriceBet.sol";

contract GasPriceBetScript is Script {
    GasPriceBet public gasPriceBet;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        gasPriceBet = new GasPriceBet(address(0));

        vm.stopBroadcast();
    }
}
