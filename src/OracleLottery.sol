// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2} from "lib/chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "lib/chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {
    AutomationCompatibleInterface
} from "lib/chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract OracleLottery is VRFConsumerBaseV2, AutomationCompatibleInterface {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Lottery__NotOpen();
    error Lottery__IncorrectETH();
    error Lottery__AlreadyEntered();
    error Lottery__UpkeepNotNeeded();
    error Lottery__NotDrawing();
    error Lottery__ETHTransferFailed();
    error Lottery__TimeoutNotReached();
    error Lottery__NotFailed();
    error Lottery__NoRefund();
    error Lottery__RefundFailed();
    error Lottery__WrongRequestId();
    error Lottery__RefundsPending();
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Entered(address indexed player);
    event RandomnessRequested(uint256 indexed requestId);
    event WinnerSelected(address indexed winner);
    event LotteryFailed();
    event Refunded(address indexed player, uint256 amount);

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

    VRFCoordinatorV2Interface private immutable vrfCoordinator;

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

    /*//////////////////////////////////////////////////////////////
                          ENTRY FUNCTION
    //////////////////////////////////////////////////////////////*/

    function enter() external payable {
        if (state != LotteryState.Open) {
            revert Lottery__NotOpen();
        }
        if (hasEntered[msg.sender]) {
            revert Lottery__AlreadyEntered();
        }
        if (msg.value != entranceFee) {
            revert Lottery__IncorrectETH();
        }

        hasEntered[msg.sender] = true;
        players.push(payable(msg.sender));

        refundableAmount[msg.sender] = entranceFee;
        totalPot += msg.value;

        emit Entered(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                     AUTOMATION (CHECK)
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        // (bytes calldata) unused input required by Chainlink interface
        bool timePassed = (block.timestamp - lastTimestamp) >= interval;
        bool hasPlayers = players.length > 0;
        bool isOpen = state == LotteryState.Open;
        bool accountingOk = address(this).balance == totalPot;

        upkeepNeeded = timePassed && hasPlayers && isOpen && accountingOk;
    }

    /*//////////////////////////////////////////////////////////////
                     AUTOMATION (PERFORM)
    //////////////////////////////////////////////////////////////*/
    function performUpkeep(bytes calldata) external override {
        (bool upkeepNeeded,) = this.checkUpkeep("");
        if (!upkeepNeeded) {
            revert Lottery__UpkeepNotNeeded();
        }

        state = LotteryState.Drawing;
        drawingStartedAt = block.timestamp;

        vrfRequestId = vrfCoordinator.requestRandomWords(
            gasLane,
            subscriptionId,
            3, // confirmations
            callbackGasLimit,
            1 // numWords
        );
        emit RandomnessRequested(vrfRequestId);
    }

    /*//////////////////////////////////////////////////////////////
                        VRF CALLBACK
    //////////////////////////////////////////////////////////////*/

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (state != LotteryState.Drawing) revert Lottery__NotDrawing();
        if (requestId != vrfRequestId) revert Lottery__WrongRequestId();

        uint256 winnerIndex = randomWords[0] % players.length;
        address payable winner = players[winnerIndex];
        recentWinner = winner;

        uint256 payout = totalPot;

        // Reset per-round mappings
        for (uint256 i = 0; i < players.length; i++) {
            address p = players[i];
            hasEntered[p] = false;
            refundableAmount[p] = 0;
        }

        delete players;
        totalPot = 0;

        // Interaction
        (bool success,) = winner.call{value: payout}("");
        if (!success) revert Lottery__ETHTransferFailed();

        emit WinnerSelected(winner);

        // Start next round
        lastTimestamp = block.timestamp;
        state = LotteryState.Open;
    }

    /*//////////////////////////////////////////////////////////////
                      FAILURE TRANSITION
    //////////////////////////////////////////////////////////////*/

    function triggerFailure() external {
        if (state != LotteryState.Drawing) {
            revert Lottery__NotDrawing();
        }
        if (block.timestamp - drawingStartedAt < drawTimeout) {
            revert Lottery__TimeoutNotReached();
        }

        state = LotteryState.Failed;

        emit LotteryFailed();
    }

    /*//////////////////////////////////////////////////////////////
                          REFUND LOGIC
    //////////////////////////////////////////////////////////////*/

    function refund() external {
        if (state != LotteryState.Failed) {
            revert Lottery__NotFailed();
        }

        uint256 amount = refundableAmount[msg.sender];
        if (amount == 0) {
            revert Lottery__NoRefund();
        }

        refundableAmount[msg.sender] = 0;
        hasEntered[msg.sender] = false;
        totalPot -= amount;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) {
            revert Lottery__RefundFailed();
        }

        emit Refunded(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        RESTART AFTER FAILURE
    //////////////////////////////////////////////////////////////*/

    function restart() external {
        if (state != LotteryState.Failed) {
            revert Lottery__NotFailed();
        }

        // Ensure no funds remain to be claimed
        if (totalPot != 0) {
            revert Lottery__RefundsPending();
        }

        // Reset round state
        delete players;
        lastTimestamp = block.timestamp;
        state = LotteryState.Open;
    }

    /*//////////////////////////////////////////////////////////////
                          GETTERS
    //////////////////////////////////////////////////////////////*/

    function getState() external view returns (LotteryState) {
        return state;
    }

    function getLastTimestamp() external view returns (uint256) {
        return lastTimestamp;
    }

    function getDrawingStartedAt() external view returns (uint256) {
        return drawingStartedAt;
    }

    function getInterval() external view returns (uint256) {
        return interval;
    }

    function getDrawTimeout() external view returns (uint256) {
        return drawTimeout;
    }

    function getTotalPot() external view returns (uint256) {
        return totalPot;
    }

    function getNumberOfPlayers() external view returns (uint256) {
        return players.length;
    }

    function getPlayer(uint256 index) external view returns (address) {
        return players[index];
    }

    function getRecentWinner() external view returns (address) {
        return recentWinner;
    }

    function getEntranceFee() external view returns (uint256) {
        return entranceFee;
    }

    function getSubscriptionId() external view returns (uint64) {
        return subscriptionId;
    }

    function getCallbackGasLimit() external view returns (uint32) {
        return callbackGasLimit;
    }
}
