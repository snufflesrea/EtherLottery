// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {EtherLottery} from "../src/EtherLottery.sol";

contract EtherLotteryScript is Script {
    EtherLottery public etherLottery;

    function setUp() public {}

    function run() public {
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subscriptionId = vm.envUint("SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("KEY_HASH");

        vm.startBroadcast();

        etherLottery = new EtherLottery(vrfCoordinator, subscriptionId, keyHash);

        vm.stopBroadcast();

        console.log("EtherLottery deployed at:", address(etherLottery));

        // Let the frontend know where the contract lives.
        // Needs fs_permissions for ./frontend in foundry.toml.
        string memory config = string.concat(
            "window.ETHER_LOTTERY = { address: \"",
            vm.toString(address(etherLottery)),
            "\", chainId: ",
            vm.toString(block.chainid),
            " };\n"
        );
        vm.writeFile("frontend/config.js", config);
        console.log("Wrote frontend/config.js");
    }
}
