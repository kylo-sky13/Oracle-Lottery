// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2} from "lib/chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "lib/chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {
    AutomationCompatibleInterface
} from "lib/chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract OracleLottery is VRFConsumerBaseV2, AutomationCompatibleInterface {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /* Type declarations */
    enum LotteryState {
        Open,
        Closed,
        Drawing,
        Completed,
        Failed
    }

    LotteryState private state;

    /*//////////////////////////////////////////////////////////////
                           PLAYER STORAGE
    //////////////////////////////////////////////////////////////*/

    // Unique list of players (one entry per address)
    address payable[] private players;

    // Enforces one entry per address
    mapping(address => bool) private hasEntered;

    // Pull-based refund accounting (used only in Failed state)
    mapping(address => uint256) private refundableAmount;

    /*//////////////////////////////////////////////////////////////
                          ETH ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    // Total ETH committed to the lottery (protocol accounting)
    uint256 private totalPot;

    /*//////////////////////////////////////////////////////////////
                           TIME TRACKING
    //////////////////////////////////////////////////////////////*/

    // Timestamp of last successful state progression (used for interval)
    uint256 private lastTimestamp;

    // Timestamp when Drawing state began (used for VRF timeout)
    uint256 private drawingStartedAt;

    // Minimum time between rounds
    uint256 private interval;

    // Maximum time to wait for VRF before failure
    uint256 private drawTimeout;

    /*//////////////////////////////////////////////////////////////
                        ORACLE / VRF STATE
    //////////////////////////////////////////////////////////////*/

    // Latest VRF request id (guards against double-fulfillment)
    uint256 private vrfRequestId;

    // Winner recorded after successful completion
    address private recentWinner;

    /*//////////////////////////////////////////////////////////////
                     IMMUTABLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    // Fixed ETH required to enter
    uint256 private immutable entranceFee;

    // Chainlink VRF configuration (fixed at deploy)
    uint64 private immutable subscriptionId;
    bytes32 private immutable gasLane;
    uint32 private immutable callbackGasLimit;
    address private immutable vrfCoordinator;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _entranceFee,
        uint256 _interval,
        uint256 _drawTimeout,
        uint64 _subscriptionId,
        bytes32 _gasLane,
        uint32 _callbackGasLimit,
        address _vrfCoordinator
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        entranceFee = _entranceFee;
        interval = _interval;
        drawTimeout = _drawTimeout;

        subscriptionId = _subscriptionId;
        gasLane = _gasLane;
        callbackGasLimit = _callbackGasLimit;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);

        state = LotteryState.Open;
        lastTimestamp = block.timestamp;
    }
}
