// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleLottery} from "../../src/OracleLottery.sol";
import {VRFCoordinatorV2Mock} from "lib/chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";

contract OracleLotteryTest is Test {
    OracleLottery lottery;
    VRFCoordinatorV2Mock vrfMock;

    address player1 = address(0x1);
    address player2 = address(0x2);

    uint256 constant ENTRANCE_FEE = 0.1 ether;
    uint256 constant INTERVAL = 1 days;
    uint256 constant DRAW_TIMEOUT = 1 hours;

    // Dummy VRF config (not used in unit tests)
    uint64 SUB_ID;
    bytes32 constant GAS_LANE = bytes32("gasLane");
    uint32 constant CALLBACK_GAS = 500000;

    function setUp() public {
        vrfMock = new VRFCoordinatorV2Mock(0.1 ether, 1e9);

        SUB_ID = vrfMock.createSubscription();
        vrfMock.fundSubscription(SUB_ID, 10 ether);

        lottery =
            new OracleLottery(ENTRANCE_FEE, INTERVAL, DRAW_TIMEOUT, SUB_ID, GAS_LANE, CALLBACK_GAS, address(vrfMock));

        vrfMock.addConsumer(SUB_ID, address(lottery));

        vm.deal(player1, 10 ether);
        vm.deal(player2, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            ENTER
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfIncorrectETH() public {
        vm.prank(player1);
        vm.expectRevert(OracleLottery.Lottery__IncorrectETH.selector);
        lottery.enter{value: 0.05 ether}();
    }

    function testRevertsIfNotOpen() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        vm.prank(player2);
        vm.expectRevert(OracleLottery.Lottery__NotOpen.selector);
        lottery.enter{value: ENTRANCE_FEE}();
    }

    function testTracksPlayersAndPot() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        assertEq(lottery.getNumberOfPlayers(), 1);
        assertEq(lottery.getTotalPot(), ENTRANCE_FEE);
        assertEq(lottery.getPlayer(0), player1);
    }

    /*//////////////////////////////////////////////////////////////
                       STATE TRANSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotDrawBeforeInterval() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.expectRevert(OracleLottery.Lottery__UpkeepNotNeeded.selector);
        lottery.performUpkeep("");
    }

    function testCannotDrawTwice() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        vm.expectRevert(OracleLottery.Lottery__UpkeepNotNeeded.selector);
        lottery.performUpkeep("");
    }

    function testCannotRefundUnlessFailed() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.expectRevert(OracleLottery.Lottery__NotFailed.selector);
        lottery.refund();
    }

    /*//////////////////////////////////////////////////////////////
                         WINNER SELECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testWinnerInPlayersAndPaid() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.prank(player2);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        uint256 requestId = lottery.getVrfRequestId();
        vrfMock.fulfillRandomWords(requestId, address(lottery));

        address winner = lottery.getRecentWinner();
        bool validWinner = (winner == player1 || winner == player2);
        assertTrue(validWinner);

        assertEq(lottery.getTotalPot(), 0);
        assertEq(uint256(lottery.getState()), uint256(OracleLottery.LotteryState.Open));
    }

    /*//////////////////////////////////////////////////////////////
                           FAILURE TESTS
    //////////////////////////////////////////////////////////////*/

    function testVRFTimeoutTriggersFailed() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        vm.warp(block.timestamp + DRAW_TIMEOUT + 1);

        lottery.triggerFailure();
        assertEq(uint256(lottery.getState()), uint256(OracleLottery.LotteryState.Failed));
    }

    function testRefundRestoresFunds() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        vm.warp(block.timestamp + DRAW_TIMEOUT + 1);
        lottery.triggerFailure();

        uint256 balBefore = player1.balance;

        vm.prank(player1);
        lottery.refund();

        assertEq(player1.balance, balBefore + ENTRANCE_FEE);
    }

    function testRefundCannotBeClaimedTwice() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.warp(block.timestamp + INTERVAL + 1);
        lottery.performUpkeep("");

        vm.warp(block.timestamp + DRAW_TIMEOUT + 1);
        lottery.triggerFailure();

        vm.prank(player1);
        lottery.refund();

        vm.prank(player1);
        vm.expectRevert(OracleLottery.Lottery__NoRefund.selector);
        lottery.refund();
    }

    function testRefundNotCallableInNonFailedState() public {
        vm.prank(player1);
        lottery.enter{value: ENTRANCE_FEE}();

        vm.expectRevert(OracleLottery.Lottery__NotFailed.selector);
        lottery.refund();
    }
}
