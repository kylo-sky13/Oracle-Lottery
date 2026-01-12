# OracleLottery — Chainlink VRF + Automation Lottery

OracleLottery is a **fully on-chain, trust-minimized lottery system** using **Chainlink VRF v2** for verifiable randomness and **Chainlink Automation** for decentralized round execution.

This project is built as a **security-first engineering exercise**, focusing on:
- Explicit state machine design
- Strict ETH accounting invariants
- Failure recovery mechanisms
- Full unit + invariant test coverage

**No admin keys.**  
**No manual winner selection.**  
**No custodial funds.**

---

## Core Properties

- One entry per address per round
- Fixed entrance fee
- Winner receives entire pot
- Time-based round scheduling
- Verifiable randomness via Chainlink VRF
- Automatic draw triggering via Chainlink Automation
- Refundable failure recovery if VRF callback stalls
- Ownerless restart after refunds

---

## State Machine

```
Open → Drawing → Open (successful round)
Open → Drawing → Failed → Open (VRF timeout + refunds + restart)
```

### State Meaning

| State       | Description                                 |
| ----------- | ------------------------------------------- |
| `Open`      | Users may enter the lottery                 |
| `Drawing`   | Randomness requested, awaiting VRF callback |
| `Failed`    | VRF timeout exceeded, refunds enabled       |
| `Completed` | (Transient during payout in callback)       |

---

## Entry Rules

- Contract must be in `Open`
- Exact `entranceFee` must be sent
- Each address may only enter once per round

---

## Automation Logic

Chainlink Automation calls:

- **`checkUpkeep()`** to determine if:
  - Time interval has passed
  - Players exist
  - Contract is open
  - Internal accounting matches ETH balance

- **`performUpkeep()`** transitions to `Drawing` and requests VRF randomness

---

## Randomness & Winner Selection

Chainlink VRF calls back:

- A winner index is derived from random word
- Winner receives full pot
- Player registry resets
- New round opens automatically

Randomness is verifiable and tamper-proof.

---

## Failure Recovery

If VRF callback does not arrive within `drawTimeout`:

- Anyone may call `triggerFailure()`
- Contract enters `Failed` state
- Players can claim refunds individually
- Once all refunds claimed, anyone may call `restart()`
- New round opens without admin intervention

**This prevents ETH from ever being permanently stuck.**

---

## Security Invariants

The test suite enforces:

- Contract balance always equals `totalPot` while active
- No trapped ETH after completion
- No multiple entries per address
- Refunds only possible in `Failed` state
- No infinite `Drawing` state lock
- Player registry and mappings always consistent

---

## Testing

### Unit Tests

Located in:
```
test/Unit/OracleLotteryTest.t.sol
```

Covers:
- Entry validation
- State transitions
- Winner selection
- VRF timeout failure
- Refund behavior

### Invariant Tests

Located in:
```
test/Invariant/OracleLotteryInvariant.t.sol
```

Covers global safety properties across randomized call sequences.

### Run Tests

```bash
forge test
forge test --match-path test/Unit/OracleLotteryTest.t.sol
forge test --match-path test/Invariant/OracleLotteryInvariant.t.sol
forge coverage
```

All tests pass with invariant fuzzing enabled.

---

## Dependencies

- Foundry
- Chainlink VRF v2
- Chainlink Automation

Install via:

```bash
forge install smartcontractkit/chainlink@v2.17.0
```

---

## Deployment Notes

To deploy on a live network:

1. Create a Chainlink VRF subscription
2. Fund subscription with LINK
3. Add deployed lottery as consumer
4. Register contract with Chainlink Automation

### Constructor Parameters

- Entrance fee
- Interval between rounds
- VRF timeout
- VRF subscription ID
- Gas lane keyHash
- Callback gas limit
- VRF coordinator address

---

## Design Goals

- No privileged owner
- No manual intervention
- No hidden withdrawal paths
- Explicit failure recovery
- Audit-style invariant testing

---

## License

MIT