// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title EtherLottery
/// @notice Each coupon costs 0.001 ETH. When 10 coupons are sold, Chainlink VRF
///         picks a winner. The pot of 0.01 ETH is split: 90% (0.009 ETH) goes to
///         the winner and 10% (0.001 ETH) goes to the protocol as a fee.
///         Sales close when 10 coupons are sold OR 2 days after the first buyer
///         of the round. If the round expires with fewer than 10 coupons,
///         buyers get a full refund and no fee is taken.
contract EtherLottery is VRFConsumerBaseV2Plus {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 public constant TICKET_PRICE = 0.001 ether;
    uint256 public constant MAX_TICKETS = 10;
    uint256 public constant POT = TICKET_PRICE * MAX_TICKETS; // 0.01 ether
    uint256 public constant FEE_BPS = 1000; // 10% in basis points
    uint256 public constant PROTOCOL_FEE = (POT * FEE_BPS) / 10_000; // 0.001 ether
    uint256 public constant PRIZE = POT - PROTOCOL_FEE; // 0.009 ether
    uint256 public constant SALE_DURATION = 2 days;
    uint256 public constant DRAW_RETRY_DELAY = 1 days;
    uint256 public constant MAX_RETRIES = 3;

    // ---------------------------------------------------------------------
    // Chainlink VRF config
    // ---------------------------------------------------------------------
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    uint32 public constant CALLBACK_GAS_LIMIT = 200_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;

    // ---------------------------------------------------------------------
    // Lottery state
    // ---------------------------------------------------------------------
    enum State {
        Open, // selling coupons
        Drawing, // waiting for VRF
        Finished, // winner picked
        Refundable // expired before 10 coupons were sold
    }

    struct Round {
        address[] players; // one entry per coupon
        uint256 startTime; // time of first purchase
        uint256 drawRequestedAt;
        State state;
        address winner;
        uint256 retryCount; // number of times randomness was re-requested
    }

    uint256 public currentRound;
    mapping(uint256 => Round) private rounds;
    mapping(uint256 => uint256) public requestToRound; // VRF requestId => round
    mapping(uint256 => mapping(address => uint256)) public ticketsOf; // round => player => coupons
    mapping(address => uint256) public pendingPrize; // winnings to withdraw
    uint256 public protocolFees; // accumulated fees the owner can withdraw

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event TicketBought(uint256 indexed round, address indexed buyer, uint256 ticketNumber);
    event DrawRequested(uint256 indexed round, uint256 indexed requestId);
    event WinnerPicked(uint256 indexed round, address indexed winner, uint256 prize);
    event RoundExpired(uint256 indexed round);
    event Refunded(uint256 indexed round, address indexed player, uint256 amount);
    event PrizeWithdrawn(address indexed winner, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(address vrfCoordinator, uint256 _subscriptionId, bytes32 _keyHash)
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    // ---------------------------------------------------------------------
    // Buy a coupon
    // ---------------------------------------------------------------------
    function buyTicket() external payable {
        require(msg.value == TICKET_PRICE, "Send exactly 0.001 ETH");

        Round storage r = rounds[currentRound];

        // Expire the current round if its 2 day window passed
        if (r.state == State.Open && _isExpired(r)) {
            _expire(currentRound);
        }

        // Start a new round if the previous one is no longer open
        if (rounds[currentRound].state != State.Open) {
            require(rounds[currentRound].state != State.Drawing, "Draw in progress");
            currentRound++;
        }

        uint256 roundId = currentRound;
        r = rounds[roundId];

        if (r.players.length == 0) {
            r.startTime = block.timestamp;
        }

        r.players.push(msg.sender);
        ticketsOf[roundId][msg.sender]++;
        emit TicketBought(roundId, msg.sender, r.players.length);

        // 10th coupon sold: close sales and request randomness
        if (r.players.length == MAX_TICKETS) {
            _requestDraw(roundId);
        }
    }

    // ---------------------------------------------------------------------
    // Expiry & refunds (round ended with fewer than 10 coupons)
    // ---------------------------------------------------------------------
    /// @notice Anyone can mark an expired round as refundable.
    function closeExpiredRound(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(r.state == State.Open && _isExpired(r), "Not expired");
        _expire(roundId);
    }

    function claimRefund(uint256 roundId) external {
        require(rounds[roundId].state == State.Refundable, "Not refundable");
        uint256 count = ticketsOf[roundId][msg.sender];
        require(count > 0, "Nothing to refund");

        ticketsOf[roundId][msg.sender] = 0;
        uint256 amount = count * TICKET_PRICE;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Refund failed");
        emit Refunded(roundId, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Chainlink VRF
    // ---------------------------------------------------------------------
    function _requestDraw(uint256 roundId) internal {
        Round storage r = rounds[roundId];
        r.state = State.Drawing;
        r.drawRequestedAt = block.timestamp;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        requestToRound[requestId] = roundId;
        emit DrawRequested(roundId, requestId);
    }

    /// @notice Re-request randomness if VRF has not answered after 1 day.
    function retryDraw(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(r.state == State.Drawing, "Not drawing");
        require(block.timestamp >= r.drawRequestedAt + DRAW_RETRY_DELAY, "Too early");
        require(r.retryCount < MAX_RETRIES); // or restrict to owner/keeper role
        _requestDraw(roundId);
        r.retryCount++;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = requestToRound[requestId];
        Round storage r = rounds[roundId];

        // Ignore duplicate / late responses
        if (r.state != State.Drawing) return;

        address winner = r.players[randomWords[0] % MAX_TICKETS];
        r.winner = winner;
        r.state = State.Finished;

        // Pull-payment: winner withdraws, so the VRF callback can never fail
        pendingPrize[winner] += PRIZE;
        protocolFees += PROTOCOL_FEE;

        emit WinnerPicked(roundId, winner, PRIZE);
    }

    // ---------------------------------------------------------------------
    // Winner withdraws prize
    // ---------------------------------------------------------------------
    function withdrawPrize() external {
        uint256 amount = pendingPrize[msg.sender];
        require(amount > 0, "No prize");

        pendingPrize[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit PrizeWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Protocol fee (owner only)
    // ---------------------------------------------------------------------
    /// @notice Withdraw the accumulated 10% protocol fees to the owner.
    function withdrawFees() external onlyOwner {
        uint256 amount = protocolFees;
        require(amount > 0, "No fees");

        protocolFees = 0;
        (bool ok,) = owner().call{value: amount}("");
        require(ok, "Transfer failed");
        emit FeesWithdrawn(owner(), amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function getRound(uint256 roundId)
        external
        view
        returns (address[] memory players, uint256 startTime, uint256 endTime, State state, address winner)
    {
        Round storage r = rounds[roundId];
        return (r.players, r.startTime, r.startTime == 0 ? 0 : r.startTime + SALE_DURATION, r.state, r.winner);
    }

    function ticketsSold() external view returns (uint256) {
        return rounds[currentRound].players.length;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------
    function _isExpired(Round storage r) internal view returns (bool) {
        return r.players.length > 0 && block.timestamp > r.startTime + SALE_DURATION;
    }

    function _expire(uint256 roundId) internal {
        rounds[roundId].state = State.Refundable;
        emit RoundExpired(roundId);
    }
}
