// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2} from "lib/chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "lib/chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {
    AutomationCompatibleInterface
} from "lib/chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/// @title OracleLottery
/// @author kylo_sky
/// @notice A fully on-chain lottery using Chainlink VRF for randomness and
///         Chainlink Automation for trustless round execution.
/// @dev One entry per address. Fixed entrance fee. Winner receives full pot.
///      Includes timeout-based failure recovery and pull-based refunds.
///
/// State Machine:
/// Open -> Drawing -> Open (success)
/// Open -> Drawing -> Failed -> Open (refund + restart)

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

    /// @notice Emitted when a player successfully enters
    event Entered(address indexed player);

    /// @notice Emitted when randomness request is sent to Chainlink VRF
    event RandomnessRequested(uint256 indexed requestId);

    /// @notice Emitted when a winner is selected and paid
    event WinnerSelected(address indexed winner);

    /// @notice Emitted if VRF callback times out and lottery enters Failed state
    event LotteryFailed();

    /// @notice Emitted when a player successfully claims a refund
    event Refunded(address indexed player, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle states of the lottery
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

    /// @notice Unique list of current round participants (one entry per address)
    address payable[] private players;

    /// @notice Ensures each address may only enter once per round
    mapping(address => bool) private hasEntered;

    /// @notice Tracks refundable balances if lottery enters Failed state
    mapping(address => uint256) private refundableAmount;

    /*//////////////////////////////////////////////////////////////
                          ETH ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal accounting of total ETH committed to current round(protocol accounting)
    uint256 private totalPot;

    /*//////////////////////////////////////////////////////////////
                           TIME TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Timestamp of last completed round (used for interval)
    uint256 private lastTimestamp;

    /// @notice Timestamp when Drawing state began (used for VRF timeout)
    uint256 private drawingStartedAt;

    /// @notice Minimum time interval between rounds
    uint256 private interval;

    /// @notice Maximum wait time for VRF callback before failure
    uint256 private drawTimeout;

    /*//////////////////////////////////////////////////////////////
                        ORACLE / VRF STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Chainlink VRF Coordinator interface
    VRFCoordinatorV2Interface private immutable vrfCoordinator;

    /// @notice Latest VRF request id
    uint256 private vrfRequestId;

    /// @notice Most recent lottery winner
    address private recentWinner;

    /*//////////////////////////////////////////////////////////////
                     IMMUTABLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Fixed ETH amount required to enter
    uint256 private immutable entranceFee;

    /// @notice Chainlink VRF subscription id
    uint64 private immutable subscriptionId;

    /// @notice Chainlink VRF gas lane keyHash
    bytes32 private immutable gasLane;

    /// @notice Gas limit for VRF callback
    uint32 private immutable callbackGasLimit;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _entranceFee ETH required to enter the lottery
    /// @param _interval Minimum time between lottery rounds
    /// @param _drawTimeout Max time to wait for VRF before failure
    /// @param _subscriptionId Chainlink VRF subscription id
    /// @param _gasLane Chainlink VRF keyHash
    /// @param _callbackGasLimit Gas limit for VRF callback
    /// @param _vrfCoordinator Address of Chainlink VRF Coordinator
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

    /// @notice Enter the lottery by paying exactly `entranceFee`
    /// @dev Reverts if not Open, incorrect ETH, or already entered
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

    /// @notice Called by Chainlink Automation to check if upkeep is needed
    /// @dev Returns true when enough time passed, players exist, state is Open,
    ///      and internal accounting matches actual ETH balance
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        // (bytes calldata) unused input required by Chainlink interface
        bool timePassed = (block.timestamp - lastTimestamp) >= interval;
        bool hasPlayers = players.length > 0;
        bool isOpen = state == LotteryState.Open;
        bool accountingOk = address(this).balance == totalPot;

        upkeepNeeded = timePassed && hasPlayers && isOpen && accountingOk;
        performData = "";
    }

    /*//////////////////////////////////////////////////////////////
                     AUTOMATION (PERFORM)
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by Chainlink Automation to start winner selection
    /// @dev Transitions to Drawing and requests VRF randomness
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

    /// @notice Callback invoked by Chainlink VRF with random number
    /// @dev Selects winner, pays out pot, resets round
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

    /// @notice Transitions to Failed state if VRF timeout is exceeded
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

    /// @notice Claim refund if lottery entered Failed state
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

    function getVrfRequestId() external view returns (uint256) {
        return vrfRequestId;
    }

    function getHasEntered(address user) external view returns (bool) {
        return hasEntered[user];
    }

    function getRefundableAmount(address user) external view returns (uint256) {
        return refundableAmount[user];
    }
}
