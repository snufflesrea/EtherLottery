// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EtherLottery} from "../src/EtherLottery.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract EtherLotteryTest is Test {
    EtherLottery internal lottery;
    VRFCoordinatorV2_5Mock internal vrf;
    uint256 internal subId;

    bytes32 internal constant KEY_HASH = bytes32(uint256(1));
    uint256 internal constant PRICE = 0.001 ether;
    uint256 internal constant MAX = 10;

    address[10] internal players;

    event TicketBought(uint256 indexed round, address indexed buyer, uint256 ticketNumber);
    event DrawRequested(uint256 indexed round, uint256 indexed requestId);
    event WinnerPicked(uint256 indexed round, address indexed winner, uint256 prize);

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------
    function setUp() public {
        // baseFee, gasPrice, weiPerUnitLink
        vrf = new VRFCoordinatorV2_5Mock(0.25 ether, 1e9, 4e15);
        subId = vrf.createSubscription();
        vrf.fundSubscription(subId, 100 ether);

        lottery = new EtherLottery(address(vrf), subId, KEY_HASH);
        vrf.addConsumer(subId, address(lottery));

        for (uint256 i = 0; i < MAX; i++) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
            vm.deal(players[i], 1 ether);
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _buy(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; i++) {
            vm.prank(players[i]);
            lottery.buyTicket{value: PRICE}();
        }
    }

    function _state(uint256 roundId) internal view returns (EtherLottery.State s) {
        (, , , s, ) = lottery.getRound(roundId);
    }

    function _winner(uint256 roundId) internal view returns (address w) {
        (, , , , w) = lottery.getRound(roundId);
    }

    function _isPlayer(address a) internal view returns (bool) {
        for (uint256 i = 0; i < MAX; i++) {
            if (players[i] == a) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // Buying
    // ---------------------------------------------------------------------
    function test_BuyTicket_Succeeds() public {
        vm.expectEmit(true, true, false, true);
        emit TicketBought(0, players[0], 1);

        _buy(0, 1);

        assertEq(lottery.ticketsSold(), 1);
        assertEq(lottery.ticketsOf(0, players[0]), 1);
        assertEq(address(lottery).balance, PRICE);
        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Open));
    }

    function test_BuyTicket_RevertsOnWrongAmount() public {
        vm.startPrank(players[0]);

        vm.expectRevert("Send exactly 0.001 ETH");
        lottery.buyTicket{value: 0.002 ether}();

        vm.expectRevert("Send exactly 0.001 ETH");
        lottery.buyTicket{value: 0}();

        vm.stopPrank();
    }

    function test_SamePlayerCanBuyMultipleTickets() public {
        vm.startPrank(players[0]);
        lottery.buyTicket{value: PRICE}();
        lottery.buyTicket{value: PRICE}();
        vm.stopPrank();

        assertEq(lottery.ticketsOf(0, players[0]), 2);
        assertEq(lottery.ticketsSold(), 2);
    }

    function test_StartTimeSetOnFirstPurchase() public {
        vm.warp(1_000_000);
        _buy(0, 1);

        (, uint256 start, uint256 end, , ) = lottery.getRound(0);
        assertEq(start, 1_000_000);
        assertEq(end, 1_000_000 + 22 days);
    }

    // ---------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------
    function test_TenthTicketRequestsDraw() public {
        _buy(0, 9);
        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Open));

        vm.expectEmit(true, false, false, false);
        emit DrawRequested(0, 1);

        _buy(9, 10);

        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Drawing));
        assertEq(address(lottery).balance, PRICE * MAX);
    }

    function test_CannotBuyWhileDrawing() public {
        _buy(0, 10);

        vm.prank(players[0]);
        vm.expectRevert("Draw in progress");
        lottery.buyTicket{value: PRICE}();
    }

    function test_VRFFulfillPicksWinnerAndCreditsPrize() public {
        _buy(0, 10);

        vrf.fulfillRandomWords(1, address(lottery));

        address winner = _winner(0);
        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Finished));
        assertTrue(_isPlayer(winner));
        assertEq(lottery.pendingPrize(winner), 0.009 ether);
    }

    function test_WinnerCanWithdrawPrize() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));

        address winner = _winner(0);
        uint256 before = winner.balance;

        vm.prank(winner);
        lottery.withdrawPrize();

        assertEq(winner.balance, before + 0.009 ether);
        assertEq(lottery.pendingPrize(winner), 0);
        // only the protocol fee is left in the contract
        assertEq(address(lottery).balance, lottery.PROTOCOL_FEE());
    }

    function test_WithdrawPrize_RevertsWhenNothingToWithdraw() public {
        vm.prank(players[0]);
        vm.expectRevert("No prize");
        lottery.withdrawPrize();
    }

    function test_WinnerCannotWithdrawTwice() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));
        address winner = _winner(0);

        vm.startPrank(winner);
        lottery.withdrawPrize();
        vm.expectRevert("No prize");
        lottery.withdrawPrize();
        vm.stopPrank();
    }

    function test_NewRoundStartsAfterFinish() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));

        _buy(0, 1);

        assertEq(lottery.currentRound(), 1);
        assertEq(lottery.ticketsSold(), 1);
        assertEq(uint256(_state(1)), uint256(EtherLottery.State.Open));
    }

    // ---------------------------------------------------------------------
    // Retry draw
    // ---------------------------------------------------------------------
    function test_RetryDraw_RevertsIfNotDrawing() public {
        _buy(0, 3);
        vm.expectRevert("Not drawing");
        lottery.retryDraw(0);
    }

    function test_RetryDraw_RevertsIfTooEarly() public {
        _buy(0, 10);
        vm.expectRevert("Too early");
        lottery.retryDraw(0);
    }

    function test_RetryDraw_WorksAfterDelayAndIgnoresLateResponse() public {
        _buy(0, 10);

        vm.warp(block.timestamp + 1 days);
        lottery.retryDraw(0); // new requestId = 2

        vrf.fulfillRandomWords(2, address(lottery));
        address winner = _winner(0);
        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Finished));
        assertEq(lottery.pendingPrize(winner), 0.009 ether);

        // Late response to the first request must not pay a second prize
        vrf.fulfillRandomWords(1, address(lottery));
        assertEq(_winner(0), winner);

        uint256 totalPending;
        for (uint256 i = 0; i < MAX; i++) {
            totalPending += lottery.pendingPrize(players[i]);
        }
        assertEq(totalPending, 0.009 ether);
    }

    // ---------------------------------------------------------------------
    // Expiry and refunds
    // ---------------------------------------------------------------------
    function test_CloseExpiredRound_RevertsBeforeExpiry() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days); // exactly at the limit, not past it
        vm.expectRevert("Not expired");
        lottery.closeExpiredRound(0);
    }

    function test_ExpiredRoundBecomesRefundable() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);

        lottery.closeExpiredRound(0);

        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Refundable));
    }

    function test_ClaimRefund() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);
        lottery.closeExpiredRound(0);

        uint256 before = players[0].balance;
        vm.prank(players[0]);
        lottery.claimRefund(0);

        assertEq(players[0].balance, before + PRICE);
        assertEq(lottery.ticketsOf(0, players[0]), 0);
    }

    function test_ClaimRefund_MultipleTickets() public {
        vm.startPrank(players[0]);
        lottery.buyTicket{value: PRICE}();
        lottery.buyTicket{value: PRICE}();
        vm.stopPrank();

        vm.warp(block.timestamp + 22 days + 1);
        lottery.closeExpiredRound(0);

        uint256 before = players[0].balance;
        vm.prank(players[0]);
        lottery.claimRefund(0);

        assertEq(players[0].balance, before + 2 * PRICE);
    }

    function test_ClaimRefund_RevertsTwice() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);
        lottery.closeExpiredRound(0);

        vm.startPrank(players[0]);
        lottery.claimRefund(0);
        vm.expectRevert("Nothing to refund");
        lottery.claimRefund(0);
        vm.stopPrank();
    }

    function test_ClaimRefund_RevertsIfRoundNotRefundable() public {
        _buy(0, 3);
        vm.prank(players[0]);
        vm.expectRevert("Not refundable");
        lottery.claimRefund(0);
    }

    function test_ClaimRefund_RevertsForNonBuyer() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);
        lottery.closeExpiredRound(0);

        vm.prank(players[9]);
        vm.expectRevert("Nothing to refund");
        lottery.claimRefund(0);
    }

    function test_BuyAfterExpiryStartsNewRound() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);

        _buy(3, 4); // auto-expires round 0 and opens round 1

        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Refundable));
        assertEq(lottery.currentRound(), 1);
        assertEq(lottery.ticketsSold(), 1);
        assertEq(uint256(_state(1)), uint256(EtherLottery.State.Open));

        // Old buyers can still refund from round 0
        uint256 before = players[0].balance;
        vm.prank(players[0]);
        lottery.claimRefund(0);
        assertEq(players[0].balance, before + PRICE);
    }

    function test_FullRoundBeforeExpiryStillDraws() public {
        _buy(0, 9);
        vm.warp(block.timestamp + 21 days);
        _buy(9, 10);

        assertEq(uint256(_state(0)), uint256(EtherLottery.State.Drawing));
    }

    // ---------------------------------------------------------------------
    // Protocol fee
    // ---------------------------------------------------------------------
    receive() external payable {} // the test contract is the owner and receives fees

    function test_FeeConstants() public view {
        assertEq(lottery.POT(), 0.01 ether);
        assertEq(lottery.PROTOCOL_FEE(), 0.001 ether);
        assertEq(lottery.PRIZE(), 0.009 ether);
        assertEq(lottery.PRIZE() + lottery.PROTOCOL_FEE(), PRICE * MAX);
    }

    function test_FeeAccruesWhenRoundFinishes() public {
        _buy(0, 10);
        assertEq(lottery.protocolFees(), 0);

        vrf.fulfillRandomWords(1, address(lottery));

        assertEq(lottery.protocolFees(), 0.001 ether);
    }

    function test_ContractBalanceEqualsPrizePlusFees() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));

        assertEq(
            address(lottery).balance,
            lottery.pendingPrize(_winner(0)) + lottery.protocolFees()
        );
    }

    function test_OwnerCanWithdrawFees() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));

        uint256 before = address(this).balance;
        lottery.withdrawFees();

        assertEq(address(this).balance, before + 0.001 ether);
        assertEq(lottery.protocolFees(), 0);
    }

    function test_FeesAccumulateAcrossRounds() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));
        _buy(0, 10); // round 1
        vrf.fulfillRandomWords(2, address(lottery));

        assertEq(lottery.protocolFees(), 0.002 ether);
    }

    function test_WithdrawFees_RevertsForNonOwner() public {
        _buy(0, 10);
        vrf.fulfillRandomWords(1, address(lottery));

        vm.prank(players[0]);
        vm.expectRevert();
        lottery.withdrawFees();
    }

    function test_WithdrawFees_RevertsWhenNoFees() public {
        vm.expectRevert("No fees");
        lottery.withdrawFees();
    }

    function test_RefundTakesNoFee() public {
        _buy(0, 3);
        vm.warp(block.timestamp + 22 days + 1);
        lottery.closeExpiredRound(0);

        uint256 before = players[0].balance;
        vm.prank(players[0]);
        lottery.claimRefund(0);

        assertEq(players[0].balance, before + PRICE); // full price back
        assertEq(lottery.protocolFees(), 0);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------
    function testFuzz_WinnerAlwaysAPlayer(uint256 randomWord) public {
        _buy(0, 10);

        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        vrf.fulfillRandomWordsWithOverride(1, address(lottery), words);

        assertTrue(_isPlayer(_winner(0)));
        assertEq(lottery.pendingPrize(_winner(0)), 0.009 ether);
    }
}
