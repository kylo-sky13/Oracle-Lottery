// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {OracleLottery} from "../../src/OracleLottery.sol";
import {VRFCoordinatorV2Mock} from "lib/chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";

/*
Invariant Suite for OracleLottery

Global properties we must ALWAYS preserve:

1. Contract ETH balance == totalPot in Open or Drawing state
2. No ETH remains trapped after Completed
3. totalPot never exceeds sum of all entrance fees paid
4. A player cannot have hasEntered=true if not in players[]
5. No refunds possible unless state == Failed
6. Cannot be stuck in Drawing forever past timeout
*/

contract OracleLotteryInvariant is StdInvariant, Test {
    OracleLottery lottery;
    VRFCoordinatorV2Mock vrfMock;

    uint256 constant ENTRANCE_FEE = 0.1 ether;
    uint256 constant INTERVAL = 1 days;
    uint256 constant DRAW_TIMEOUT = 1 hours;

    uint64 SUB_ID;
    bytes32 GAS_LANE = bytes32("gasLane");
    uint32 CALLBACK_GAS = 500000;

    function setUp() public {
        vrfMock = new VRFCoordinatorV2Mock(0.1 ether, 1e9);
        SUB_ID = vrfMock.createSubscription();
        vrfMock.fundSubscription(SUB_ID, 10 ether);

        lottery =
            new OracleLottery(ENTRANCE_FEE, INTERVAL, DRAW_TIMEOUT, SUB_ID, GAS_LANE, CALLBACK_GAS, address(vrfMock));

        vrfMock.addConsumer(SUB_ID, address(lottery));

        // Target contract for invariant fuzzing
        targetContract(address(lottery));
    }

    /*//////////////////////////////////////////////////////////////
                         INVARIANT: ETH ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function invariant_balanceMatchesPotWhenActive() public view {
        OracleLottery.LotteryState state = lottery.getState();

        if (state == OracleLottery.LotteryState.Open || state == OracleLottery.LotteryState.Drawing) {
            assertEq(address(lottery).balance, lottery.getTotalPot());
        }
    }

    function invariant_noEthTrappedAfterCompletion() public view {
        OracleLottery.LotteryState state = lottery.getState();
        if (state == OracleLottery.LotteryState.Completed) {
            assertEq(address(lottery).balance, 0);
            assertEq(lottery.getTotalPot(), 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT: PLAYER REGISTRY CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    function invariant_playersMappingConsistent() public view {
        uint256 len = lottery.getNumberOfPlayers();

        for (uint256 i = 0; i < len; i++) {
            address player = lottery.getPlayer(i);
            assertTrue(lottery.getHasEntered(player));
        }
    }

    /*//////////////////////////////////////////////////////////////
                     INVARIANT: REFUND CONDITIONS
    //////////////////////////////////////////////////////////////*/

    function invariant_refundOnlyInFailedState() public view {
        OracleLottery.LotteryState state = lottery.getState();
        if (state != OracleLottery.LotteryState.Failed) {
            // No address may have refundable balance if not failed
            uint256 len = lottery.getNumberOfPlayers();
            for (uint256 i = 0; i < len; i++) {
                address player = lottery.getPlayer(i);
                assertEq(lottery.getRefundableAmount(player), 0);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                  INVARIANT: DRAWING CANNOT STALL FOREVER
    //////////////////////////////////////////////////////////////*/

    function invariant_notStuckInDrawingPastTimeout() public view {
        OracleLottery.LotteryState state = lottery.getState();
        if (state == OracleLottery.LotteryState.Drawing) {
            // If timeout passed, upkeep must report true
            (bool upkeepNeeded,) = lottery.checkUpkeep("");
            uint256 drawingStart = lottery.getDrawingStartedAt();

            if (block.timestamp > drawingStart + DRAW_TIMEOUT) {
                assertTrue(upkeepNeeded);
            }
        }
    }
}
