# GasPriceBet

### Introduction

**GasPriceBet** is a decentralized on-chain game where players compete to predict the baseFeePerGas of a specific future block on EVM. The game is organized into continuous, overlapping rounds, each spanning 2000 blocks. In each round, players have a 1000-block window to place bets by sending ETH directly to the contract. After another 1000 blocks, the "guess block" is reached, and the contract fetches the block header's baseFeePerGas. Players who guessed closest to that baseFee (converted into a three-digit number [100..999]) win their group's prize pool.

### How the Game Works

1. **Rounds and Timing:**

   - The first round starts at block 30,000.
   - Each round `n`:
     - **Betting phase:** from `roundStartBlock = 30000 + (n-1)*1000` to `roundStartBlock + 999`.
       For example, round 1: 30,000 to 30,999 (inclusive).
       Round 2: 31,000 to 31,999, and so forth.
     - **Wait period:** After betting closes, we wait another 1000 blocks until `guessBlock = roundStartBlock + 2000`.
       For round 1, the guess block is 32,000.
       For round 2, the guess block is 33,000, etc.

   This pattern means at block 30,000 betting for round 1 starts, closes at 30,999, and at block 32,000 we know the block to guess. Meanwhile, at block 31,000, round 2 betting begins even though round 1 hasn't been resolved yet.

2. **Placing Bets:**

   - To join, a player sends ETH directly to the contract during the betting phase of some round.
   - The contract determines the round from the current `block.number`.
   - From the deposited ETH, we derive a three-digit guess [100..999] by repeatedly scaling the deposit amount until it falls into that range.
   - The number of scaling steps used to achieve [100..999] defines a "group." Different deposit magnitudes yield the same guess number but possibly with different scale factors, creating separate groups.
   - Each group within a round forms its own prize pool. Participants who scaled their deposit similarly compete only among themselves.

   **Example:**

   - If a player sends 0.3 ETH and obtains a guess of 300, they are in scaleFactor group `X`.
   - Another player who sends 3 ETH and also gets guess 300 might be in scaleFactor group `Y`.
   - These two do not compete against each other; they have separate pools.

3. **Groups:**
   - A round can have multiple groups, identified by the `scaleFactor` value found when extracting the guess.
   - Within a group, each guess (100..999) can be taken by only one player.
   - All bets in that group form a prize pool.
4. **After Betting Ends:**

   - Once the guess block is reached (e.g., block 32,000 for round 1), the contract can request the block header from a trusted HeaderProtocol contract.
   - The HeaderProtocol must respond within 256 blocks (by block 32,256 for round 1).
   - If the header doesn't arrive in time, players can withdraw their bets (no winners).

5. **Determining Winners:**

   - When the header arrives, we read the `baseFeePerGas` and convert it into a [100..999] guess using the same scaling logic.
   - The winning guess is the one closest to this computed number. If there's a tie (equal distance on both sides), two winners are declared.
   - This is done per group, meaning each group may have different winners, splitting its own prize pool.

6. **Claiming Winnings:**

   - Players claim individually using the `claim()` function.
   - The first claimer from a group after the header is known triggers the calculation of winners and their shares.
   - Winners receive a share of the pool after a 1% commission is taken.
   - If no header arrived, or no valid winning guess is found, players can withdraw their original bets.

7. **No Large Loops:**
   - To ensure gas efficiency, we never iterate over all possible guesses.
   - Guesses are stored in a sorted array, and winner determination uses binary search (O(log n)) to find the closest guess.
   - All heavy computations happen only once per group (at the first claim).

### Example Scenario

**Round 1:**

- Starts at block 30,000.
- Players bet from 30,000 to 30,999.
- Suppose player A sends 0.3 ETH at block 30,500 and gets guess = 300 in scaleFactor=some value.
- Another player B sends 0.0387 ETH at block 30,700 and gets guess = 387 in the same scaleFactor group or maybe a different one.
- At block 32,000, the guess block is reached. The contract requests the header if there's enough pool to pay for it.
- Header arrives by block 32,200 (for example), the baseFee is extracted.
- The contract computes a winning guess from baseFee. Let's say it's 295.
- The closest guess to 295 in that group might be 300.
- Player A claims first, triggering winner determination. Player A might win and gets the payout minus 1% commission.
- Player B, if not a winner, gets nothing. If the header didn't arrive by 32,256, both A and B could withdraw their original bets instead.

**Round 2:**

- Starts at block 31,000 (overlapping with round 1's wait).
- Similar logic applies.

### Security Considerations

- The contract relies on a trusted HeaderProtocol to provide a correct block header.
- If no header is received, no winners can be computed, ensuring fairness (bets are returned).
- Users can only bet during the betting phase of the round.
- Each guess is unique per group, preventing multiple users from sharing the same guess slot.
- Commission is minimal and taken only once per group's payout.
- Binary search and minimal loops prevent excessive gas usage.

### Gas Efficiency and Simplicity

- The contract avoids fallback reliance. It uses `receive()` for direct deposits.
- Winner determination is O(log n) due to binary search.
- No large arrays or loops over 1000 guesses at claim time.
- State variables and mappings are arranged to minimize storage reads/writes.

### Conclusion

**GasPriceBet** is a carefully designed contract that aligns with the requested requirements. It supports continuous rounds, multiple groups per round, fair and efficient winner determination, and safe handling of header delays or absence. The provided code and explanation serve as a comprehensive guide to its logic and approach.
