// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {OracleLottery} from "../src/OracleLottery.sol";

contract DeployOracleLottery is Script {
    function run() external {
        // Everything is signed automatically by --account
        vm.startBroadcast();

        uint64 subId = uint64(vm.envUint("VRF_SUB_ID"));

        // Sepolia VRF v2.5 coordinator
        address vrfCoordinator = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625;

        // Sepolia VRF gas lane keyHash
        bytes32 gasLane = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

        uint32 callbackGasLimit = 500000;

        new OracleLottery(
            0.01 ether, // entrance fee
            300, // interval
            1800, // draw timeout
            subId,
            gasLane,
            callbackGasLimit,
            vrfCoordinator
        );

        vm.stopBroadcast();
    }
}
