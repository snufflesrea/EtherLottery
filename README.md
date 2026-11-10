# EtherLottery

A simple EVM lottery contract that uses **Chainlink VRF v2.5** for verifiable randomness.

> ⚠️ **Unaudited.** This contract is a learning/example project. Have it audited before using it with real funds.

## How it works

| Parameter | Value |
|---|---|
| Coupon price | 0.001 ETH |
| Coupons per round | 10 |
| Prize | 0.01 ETH |
| Sale window | 22 days from the first purchase of the round |

1. Users buy coupons with `buyTicket()` by sending exactly 0.001 ETH. Each coupon is one entry.
2. Sales close when **10 coupons are sold** or **22 days after the first buyer**, whichever comes first.
3. On the 10th coupon, the contract requests a random number from Chainlink VRF.
4. When VRF responds, a winner is picked (`random % 10`) and credited 0.01 ETH.
5. The winner calls `withdrawPrize()` to collect.
6. The next `buyTicket()` call automatically starts a new round.

### If the round expires with fewer than 10 coupons

A 0.01 ETH prize can't be paid, so the round becomes **refundable**:

- Anyone can call `closeExpiredRound(roundId)` (or the next `buyTicket()` does it automatically).
- Each buyer calls `claimRefund(roundId)` to get back 0.001 ETH per coupon.

### Round lifecycle

```
Open ──(10 coupons sold)──► Drawing ──(VRF response)──► Finished
  │
  └──(22 days, < 10 coupons)──► Refundable
```

## Contract interface

### Write functions

| Function | Description |
|---|---|
| `buyTicket()` payable | Buy one coupon. Must send exactly 0.001 ETH. |
| `withdrawPrize()` | Withdraw prize winnings credited to the caller. |
| `claimRefund(uint256 roundId)` | Claim a refund from an expired round. |
| `closeExpiredRound(uint256 roundId)` | Mark an expired round as refundable. Callable by anyone. |
| `retryDraw(uint256 roundId)` | Re-request randomness if VRF hasn't answered after 1 day. |

### Read functions

| Function | Description |
|---|---|
| `currentRound()` | Current round id. |
| `ticketsSold()` | Coupons sold in the current round. |
| `getRound(roundId)` | Players, start time, end time, state, and winner of a round. |
| `ticketsOf(roundId, player)` | Coupons a player holds in a round. |
| `pendingPrize(player)` | Prize amount a player can withdraw. |

### Events

`TicketBought`, `DrawRequested`, `WinnerPicked`, `RoundExpired`, `Refunded`, `PrizeWithdrawn`

## Setup

### 1. Install dependencies

```bash
npm install @chainlink/contracts
```

Requires Solidity `^0.8.20`.

### 2. Create a VRF subscription

1. Go to [vrf.chain.link](https://vrf.chain.link) and create a **VRF v2.5** subscription on your target network.
2. Fund it with LINK (or native token, depending on the network and your setup).
3. Note the **subscription ID**.

### 3. Deploy

Constructor arguments:

| Argument | Description |
|---|---|
| `vrfCoordinator` | VRF v2.5 coordinator address for your network |
| `_subscriptionId` | Your subscription ID |
| `_keyHash` | Gas lane key hash for your network |

Get the coordinator address and key hash from the [Chainlink VRF supported networks docs](https://docs.chain.link/vrf/v2-5/supported-networks).

### 4. Add the contract as a consumer

Add the deployed contract address as a **consumer** on your VRF subscription. Without this, draw requests will fail.

## Design notes

- **Pull payments.** Prizes and refunds are withdrawn by the user rather than pushed. This keeps the VRF callback from failing if a winner is a contract that rejects ETH or burns gas.
- **Multiple coupons per address.** Allowed, one per transaction. More coupons mean a higher chance to win.
- **VRF costs.** The VRF fee is paid from your subscription balance, not by the buyers. The 10 × 0.001 ETH pot is entirely paid out as the prize.
- **Callback gas.** `CALLBACK_GAS_LIMIT` is set to 200,000. Check this against your network's limits.
- **Late VRF responses.** If a draw is retried, only the first response is used; later ones are ignored.

## Known limitations

- No owner fee, so the contract takes no profit.
- One-coupon-per-transaction means multiple transactions are needed for multiple coupons.
- Sybil resistance isn't addressed. Anyone can buy many coupons from many addresses.
- Randomness depends on the VRF subscription staying funded and the contract staying registered as a consumer.

## License

MIT
