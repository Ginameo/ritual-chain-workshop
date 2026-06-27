# Homework — Privacy-Preserving AI Bounty Judge (Commit-Reveal)

Workshop assignment: extend the AI Bounty Judge so submissions stay hidden
until judging is complete.

This repo ships a new contract — **`CommitRevealJudge`** — under
`hardhat/contracts/CommitRevealJudge.sol`. It implements the required track:
commit-reveal on a per-bounty basis.

## What changed vs `AIJudge.sol`

| Aspect | Original `AIJudge` | `CommitRevealJudge` |
|---|---|---|
| Submission phase store | `string answer` plaintext | `bytes32 hash` only |
| Phase deadlines | single `deadline` | `commitDeadline`, `revealDeadline` |
| Reveal phase | n/a | `reveal(id, answer, salt)` w/ hash check |
| Winner eligibility | any `submission[i]` | `entry[i].revealed == true` |
| Error reporting | `require` strings | typed custom errors (gas-efficient) |

## Lifecycle

1. **Open** — owner calls `openBounty(title, rubric, commitDeadline, revealDeadline)` with reward `msg.value`.
2. **Commit** — submitters call `commit(id, keccak256(answer, salt, sender, id))` before the commit deadline. Only the hash lands on-chain; plaintext stays with the participant.
3. **Reveal** — after the commit deadline, submitters call `reveal(id, answer, salt)`. The contract recomputes the hash and reverts `HashMismatch` if anything differs.
4. **Judge** — owner calls `judge(id, llmInput)` after the reveal deadline. The judge passes the LLM input (containing only revealed answers) to Ritual's `LLM_INFERENCE_PRECOMPILE (0x0802)`. Batch judging, one call.
5. **Finalize** — owner calls `finalize(id, winnerIndex)`. The contract pays the reward to the entry's `who`. Picking an unrevealed entry reverts.

## Required Solidity Functions

All four required functions are present:
- `openBounty(...)` (extends `createBounty` with two-phase deadlines)
- `commit(uint256, bytes32)`
- `reveal(uint256, string, bytes32)`
- `judge(uint256, bytes)` (alias for `judgeAll`)
- `finalize(uint256, uint256)` (matches `finalizeWinner`)

## Required Contract Rules

| Rule | Enforced At |
|---|---|
| Commit only before commit deadline | `commit()` PhaseClosed |
| Reveal only between deadlines | `reveal()` WrongPhase / PhaseClosed |
| One commit per address per bounty | `commit()` AlreadyCommitted |
| Reveal validity | `reveal()` HashMismatch |
| Unrevealed → not judgeable | `judge()` only sends revealed; view `revealedCount(id)` |
| Owner judges after reveal deadline | `judge()` WrongPhase |
| Owner finalizes only after judged | `finalize()` NotJudgedYet |
| Only one winner paid | `finalize()` clears `reward`, no re-entry |

## Test Plan

20+ unit tests in `contracts/test/CommitRevealJudge.t.sol`:

### Open Bounty
- ✅ Rejects zero reward
- ✅ Rejects `revealDeadline <= commitDeadline`
- ✅ Rejects commit deadline in the past
- ✅ Increments `nextId`

### Commit Phase
- ✅ Records valid hash
- ✅ Reverts after commit deadline (PhaseClosed)
- ✅ Rejects zero hash (NoCommitment)
- ✅ Rejects duplicate commit per address (AlreadyCommitted)
- ✅ Rejects when MAX_ENTRIES reached (TooManyEntries)

### Reveal Phase
- ✅ Accepts correct answer + salt
- ✅ Reverts before commit deadline (WrongPhase)
- ✅ Reverts after reveal deadline (PhaseClosed)
- ✅ Reverts on wrong answer (HashMismatch)
- ✅ Reverts on wrong salt (HashMismatch)
- ✅ Reverts for caller without commit (NoCommitment)
- ✅ Reverts on too-long answer (AnswerTooLong)

### Isolation
- ✅ Same plaintext+same salt+same sender across two bounties: only the correct bounty id matches
- ✅ Same plaintext from two different addresses (different salts) both reveal successfully
- ✅ `getEntry` masks unrevealed entries (returns zero address + empty string)
- ✅ `revealedCount(id)` reflects only revealed entries

### Owner guards
- ✅ `judge()` rejected for non-owner (NotOwner)
- ✅ `judge()` rejected before reveal deadline (WrongPhase)
- ✅ `finalize()` rejects winnerIndex pointing at unrevealed entry

## Architecture Note — Commit-Reveal vs Ritual-Native Hidden

**Commit-Reveal (this contract):**

| What's on-chain | What's off-chain |
|---|---|
| `Bounty` metadata | (none) |
| `Entry.hash` (commitment) | Answer plaintext (until reveal) |
| `Entry.answer` (after reveal) | Salt |
| `Bounty.aiReview` | LLM input assembly |

Plaintext answers hit the chain at least once (post-reveal) so they're visible
during `judge()` and `finalize()`. The TEE is involved only for the LLM
inference step itself.

**Ritual-Native (advanced track, design only):**

| What's on-chain | What's off-chain |
|---|---|
| Encrypted ciphertext per submitter | Plaintext answers |
| TEE public key (DKMS) | Submission bundle |
| `revealedAnswersHash` (post-judge) | Full revealedAnswersRef |
| `winnerIndex`, summary | All AI review details |

Plaintext never appears on-chain. The TEE decrypts all submissions inside
the enclave, runs batch judging, and only emits a hash + reference off-chain.
This requires the `DKMS_PRECOMPILE` (0x081B) for key management and a
custom TX type for TEE access — documented in the workshop but not required
for this contract.

**Trade-off:** commit-reveal is a generic EVM pattern (works without Ritual's
TEE), but it leaks plaintext answers at reveal time. Ritual-native is
stronger privacy but tightly coupled to the chain's TEE infrastructure.

## Reflection

> What should be public, what should stay hidden, and what should be decided
> by AI versus by a human in a bounty system?

In a bounty system, the rubric, reward amount, deadlines, and commitment
hashes should be public — participants need to know what they're competing
for, and commitment hashes serve as proof of intent without leaking the
underlying content. The salt and plaintext answer must stay private until the
reveal phase; otherwise a late participant can copy an earlier answer and
submit a marginally better version, breaking the diversity that makes
competitions interesting. During judging, plaintext becomes public anyway,
which is acceptable because by that point copying is no longer rewarded.
The judging itself is a great fit for an LLM: it scales to many submissions,
applies the rubric consistently, and is not swayed by bias or fatigue — but
the final winner selection should remain with the human bounty owner, both
because the AI can be subtly manipulated through adversarial prompts
embedded in submissions, and because some judging dimensions (originality,
strategic fit, effort) are hard to encode in a rubric. The right split is
**AI proposes, human disposes**.

## Deploy

```bash
cd hardhat
pnpm install
DEPLOYER_PRIVATE_KEY=0x... \
  npx hardhat ignition deploy ignition/modules/CommitRevealJudge.ts --network ritual
```

The `ritual` network in `hardhat.config.ts` points at
`https://rpc.ritualfoundation.org` (chainId 1979).

## Run Tests

```bash
# Foundry-style Solidity unit tests
npx hardhat test contracts/test/CommitRevealJudge.t.sol

# Or compile only:
npx solcjs --optimize --bin --abi --base-path . --include-path . \
    -o build/ contracts/CommitRevealJudge.sol
```
