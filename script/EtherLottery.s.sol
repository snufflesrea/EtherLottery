// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {EtherLotter} from "../src/EtherLottery.sol";

contract EtherLotteryScript is Script {
    EtherLotter public etherLottery;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        counter = new Counter();

        vm.stopBroadcast();
    }
}
