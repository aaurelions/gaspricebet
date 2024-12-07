// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeader.sol";
import {IHeaderProtocol} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";
import {RLPReader} from "@headerprotocol/contracts/v1/utils/RLPReader.sol";

/// @title FeeGuessingGame
/// @notice A guessing game where players bet on the baseFee of a future block.
/// @dev
/// - The game runs continuously in rounds of 1000 blocks each for betting.
/// - For round n (n >= 1):
///   - `roundStartBlock = gameStartBlock + (n-1)*1000`
///   - Betting allowed during `[roundStartBlock, roundStartBlock+999]`
///   - The guess block = `roundStartBlock + 2000`
/// - Players send ETH directly to this contract during the betting phase to make a guess.
///   The deposit amount determines a guess [100..999] and a scaleFactor (group).
/// - Each group (unique scaleFactor in a round) has its own prize pool and guesses. Players compete only within that group.
/// - After the guess block is mined, a header is requested from IHeaderProtocol. The header
///   must arrive within 256 blocks of the guess block. If it doesn't, players withdraw their bets.
/// - Once header is known, winners are determined on first claim for that group by binary searching
///   the sorted guesses for the closest guess(es) to the winning guess derived from baseFee.
/// - The contract takes 1% commission from the group's pool at the first winner claim.
/// - If no winners or no header, players get their bets back.

contract FeeGuessingGame is IHeader {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for RLPReader.Iterator;
    using RLPReader for bytes;

    //--------------------------------------------------------------------------
    // Events
    //--------------------------------------------------------------------------

    /// @notice Emitted when a bet is placed.
    /// @param user The bettor
    /// @param roundIndex The round number
    /// @param scaleFactor The scale factor (group) based on deposit magnitude
    /// @param guess The guessed number [100..999]
    /// @param amount The bet amount in ETH
    event BetPlaced(
        address indexed user,
        uint256 indexed roundIndex,
        uint8 scaleFactor,
        uint16 guess,
        uint256 amount
    );

    /// @notice Emitted when a header is requested from the protocol.
    /// @param roundIndex The round for which the header is requested
    /// @param targetBlock The guess block number
    event HeaderRequested(uint256 indexed roundIndex, uint256 targetBlock);

    /// @notice Emitted when the header is received from the protocol.
    /// @param roundIndex The round index
    /// @param targetBlock The guess block
    /// @param baseFeeWei The extracted baseFeePerGas from the header
    event HeaderReceived(
        uint256 indexed roundIndex,
        uint256 targetBlock,
        uint256 baseFeeWei
    );

    /// @notice Emitted when a user claims winnings.
    /// @param user The claimant
    /// @param roundIndex The round
    /// @param scaleFactor The group
    /// @param amount The payout
    event Claimed(
        address indexed user,
        uint256 indexed roundIndex,
        uint8 scaleFactor,
        uint256 amount
    );

    /// @notice Emitted when a user withdraws their bet if no winners or no header.
    /// @param user The bettor
    /// @param roundIndex The round
    /// @param scaleFactor The group
    /// @param amount The withdrawn bet amount
    event Withdrawn(
        address indexed user,
        uint256 indexed roundIndex,
        uint8 scaleFactor,
        uint256 amount
    );

    //--------------------------------------------------------------------------
    // Constants and State
    //--------------------------------------------------------------------------

    IHeaderProtocol public headerProtocol;
    address public owner; // for commission

    uint256 public immutable gameStartBlock;
    uint256 constant COMMISSION_PERCENT = 1; // 1%
    uint256 constant HEADER_REQUEST_FEE = 0.01 ether;
    uint16 constant MIN_GUESS = 100;
    uint16 constant MAX_GUESS = 999;

    struct Group {
        uint16[] guesses; // sorted guesses
        mapping(uint16 => address) guessToUser;
        mapping(uint16 => uint256) guessToAmount;
        uint256 totalPool;
        bool winnersComputed;
        uint16[] winners;
        bool commissionTaken;
        uint256 winnerShareSingle;
        uint256 winnerShareDouble;
    }

    struct Round {
        uint256 baseFeeWei; // 0 if not known
        mapping(uint8 => Group) groups;
    }

    mapping(uint256 => Round) public rounds;

    struct UserBet {
        uint256 roundIndex;
        uint8 scaleFactor;
        uint16 guess;
        bool claimed;
        bool withdrawn;
    }
    mapping(address => UserBet[]) public userBets;

    //--------------------------------------------------------------------------
    // Constructor
    //--------------------------------------------------------------------------

    constructor(address _headerProtocol) {
        headerProtocol = IHeaderProtocol(_headerProtocol);
        owner = msg.sender;
        gameStartBlock = block.number;
    }

    //--------------------------------------------------------------------------
    // Internal Helpers
    //--------------------------------------------------------------------------

    /// @notice Compute round index from blockNumber.
    /// @dev roundIndex = floor((blockNumber - gameStartBlock)/1000) + 1 if blockNumber >= gameStartBlock
    function _getRoundIndex(
        uint256 blockNumber
    ) internal view returns (uint256) {
        require(blockNumber >= gameStartBlock, "No rounds yet");
        return ((blockNumber - gameStartBlock) / 1000) + 1;
    }

    /// @notice Start block of a given round.
    function _roundStartBlock(
        uint256 roundIndex
    ) internal view returns (uint256) {
        return gameStartBlock + (roundIndex - 1) * 1000;
    }

    /// @notice Guess block of a given round.
    function _roundGuessBlock(
        uint256 roundIndex
    ) internal view returns (uint256) {
        return _roundStartBlock(roundIndex) + 2000;
    }

    /// @notice Check if within betting phase of a round.
    function _inBettingPhase(uint256 roundIndex) internal view returns (bool) {
        uint256 start = _roundStartBlock(roundIndex);
        return (block.number >= start && block.number <= start + 999);
    }

    /// @notice Extract guess and scaleFactor from deposit amount.
    function _extractGuessFromDeposit(
        uint256 amount
    ) internal pure returns (uint16 guess, uint8 scaleFactor) {
        uint256 scaled = amount;
        for (uint8 i = 0; i < 18; i++) {
            scaled = (scaled * 10) / 1e18;
            if (scaled >= 100 && scaled <= 999) {
                return (uint16(scaled), i);
            }
            if (scaled > 999) {
                break;
            }
        }
        revert("Invalid guess");
    }

    /// @notice Insert a guess into a sorted array.
    function _insertGuessSorted(uint16[] storage arr, uint16 g) internal {
        uint256 low = 0;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (arr[mid] < g) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        arr.push(0);
        for (uint256 i = arr.length - 1; i > low; i--) {
            arr[i] = arr[i - 1];
        }
        arr[low] = g;
    }

    /// @notice Compute winning guess from baseFee.
    function _computeWinningGuess(uint256 fee) internal pure returns (uint16) {
        uint256 scaled = fee;
        for (uint8 i = 0; i < 18; i++) {
            scaled = (scaled * 10) / 1e18;
            if (scaled >= 100 && scaled <= 999) {
                return uint16(scaled);
            }
            if (scaled > 999) break;
        }
        return 0; // no valid guess
    }

    /// @notice Find closest guesses to a key via binary search.
    function _findClosestGuesses(
        uint16[] storage arr,
        uint16 key
    ) internal view returns (uint16[] memory closest) {
        if (arr.length == 0) {
            return new uint16[](0);
        }

        uint256 low = 0;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (arr[mid] < key) low = mid + 1;
            else high = mid;
        }

        uint16 leftGuess = (low > 0) ? arr[low - 1] : 0;
        uint16 rightGuess = (low < arr.length) ? arr[low] : 0;

        if (leftGuess == 0 && rightGuess == 0) {
            return new uint16[](0);
        } else if (leftGuess == 0) {
            closest = new uint16[](1);
            closest[0] = rightGuess;
        } else if (rightGuess == 0) {
            closest = new uint16[](1);
            closest[0] = leftGuess;
        } else {
            uint256 diffLeft = (leftGuess > key)
                ? (leftGuess - key)
                : (key - leftGuess);
            uint256 diffRight = (rightGuess > key)
                ? (rightGuess - key)
                : (key - rightGuess);
            if (diffLeft < diffRight) {
                closest = new uint16[](1);
                closest[0] = leftGuess;
            } else if (diffRight < diffLeft) {
                closest = new uint16[](1);
                closest[0] = rightGuess;
            } else {
                // tie
                closest = new uint16[](2);
                if (leftGuess < rightGuess) {
                    closest[0] = leftGuess;
                    closest[1] = rightGuess;
                } else {
                    closest[0] = rightGuess;
                    closest[1] = leftGuess;
                }
            }
        }
        return closest;
    }

    /// @notice Compute winners and shares for a group once we know baseFee.
    function _computeWinners(Group storage g, uint256 baseFeeWei) internal {
        require(!g.winnersComputed, "Already computed");
        uint16 winningGuess = _computeWinningGuess(baseFeeWei);
        if (winningGuess < MIN_GUESS || winningGuess > MAX_GUESS) {
            // no valid winners
            g.winners = new uint16[](0);
            g.winnersComputed = true;
            return;
        }

        uint16[] memory cls = _findClosestGuesses(g.guesses, winningGuess);
        g.winners = cls;
        g.winnersComputed = true;

        if (cls.length == 0) return; // no winners

        uint256 commission = (g.totalPool * COMMISSION_PERCENT) / 100;
        uint256 pot = g.totalPool - commission;

        if (cls.length == 1) {
            g.winnerShareSingle = pot;
        } else {
            uint256 half = pot / 2;
            uint256 remainder = pot % 2;
            g.winnerShareDouble = half + remainder; // first claimer can get remainder advantage
        }
    }

    //--------------------------------------------------------------------------
    // External Functions
    //--------------------------------------------------------------------------

    /// @notice Place a bet by sending ETH. Deduce round, scaleFactor, guess, and store bet.
    receive() external payable {
        require(msg.value > 0, "No zero bet");
        uint256 roundIndex = _getRoundIndex(block.number);
        require(_inBettingPhase(roundIndex), "Not betting phase");

        (uint16 guess, uint8 scaleFactor) = _extractGuessFromDeposit(msg.value);
        require(guess >= MIN_GUESS && guess <= MAX_GUESS, "Guess out of range");

        Round storage r = rounds[roundIndex];
        Group storage g = r.groups[scaleFactor];

        require(g.guessToUser[guess] == address(0), "Guess taken");
        g.guessToUser[guess] = msg.sender;
        g.guessToAmount[guess] = msg.value;
        g.totalPool += msg.value;
        _insertGuessSorted(g.guesses, guess);

        userBets[msg.sender].push(
            UserBet({
                roundIndex: roundIndex,
                scaleFactor: scaleFactor,
                guess: guess,
                claimed: false,
                withdrawn: false
            })
        );

        emit BetPlaced(msg.sender, roundIndex, scaleFactor, guess, msg.value);

        uint256 guessBlock = _roundGuessBlock(roundIndex);
        // If guessBlock passed and no baseFee known yet, and enough pool to request header:
        if (
            block.number >= guessBlock &&
            r.baseFeeWei == 0 &&
            g.totalPool >= HEADER_REQUEST_FEE
        ) {
            headerProtocol.request{value: HEADER_REQUEST_FEE}(guessBlock);
            emit HeaderRequested(roundIndex, guessBlock);
        }
    }

    /// @notice Called by the header protocol with the block header.
    /// @param blockNumber The guess block
    /// @param header The RLP-encoded block header
    function responseBlockHeader(
        uint256 blockNumber,
        bytes calldata header
    ) external override {
        require(msg.sender == address(headerProtocol), "Not header protocol");
        // roundIndex from blockNumber:
        // roundIndex = ((blockNumber - gameStartBlock)-2000)/1000 +1, solve for this:
        require(blockNumber >= gameStartBlock + 2000, "Block too low");
        uint256 x = blockNumber - gameStartBlock;
        uint256 roundIndex = ((x - 2000) / 1000) + 1;

        Round storage rd = rounds[roundIndex];
        require(rd.baseFeeWei == 0, "BaseFee already set");

        RLPReader.RLPItem memory item = header.toRlpItem();
        RLPReader.Iterator memory it = item.iterator();
        for (uint256 i = 0; i < 15; i++) {
            it.next();
        }
        uint256 baseFee = it.next().toUint();
        rd.baseFeeWei = baseFee;

        emit HeaderReceived(roundIndex, blockNumber, baseFee);
    }

    /// @notice Claim winnings or withdraw bet if no result.
    /// @param index The index of user's bet in userBets array.
    function claim(uint256 index) external {
        require(index < userBets[msg.sender].length, "Invalid index");
        UserBet storage ub = userBets[msg.sender][index];
        require(!ub.claimed && !ub.withdrawn, "Already settled");

        uint256 roundIndex = ub.roundIndex;
        uint8 scaleFactor = ub.scaleFactor;
        uint16 guess = ub.guess;

        Round storage r = rounds[roundIndex];
        Group storage g = r.groups[scaleFactor];

        uint256 guessBlock = _roundGuessBlock(roundIndex);

        if (r.baseFeeWei == 0) {
            // no header
            // If more than 256 blocks passed since guessBlock, no header can arrive:
            if (block.number > guessBlock + 256) {
                // withdraw bet
                uint256 amt = g.guessToAmount[guess];
                require(amt > 0, "No bet?");
                g.guessToAmount[guess] = 0;
                ub.withdrawn = true;
                (bool sent, ) = msg.sender.call{value: amt}("");
                require(sent, "Withdraw failed");
                emit Withdrawn(msg.sender, roundIndex, scaleFactor, amt);
                return;
            } else {
                revert("No result yet");
            }
        }

        // baseFee known
        if (!g.winnersComputed) {
            _computeWinners(g, r.baseFeeWei);
        }

        if (g.winners.length == 0) {
            // no winners, user withdraw bet
            uint256 amt2 = g.guessToAmount[guess];
            require(amt2 > 0, "No bet?");
            g.guessToAmount[guess] = 0;
            ub.withdrawn = true;
            (bool s2, ) = msg.sender.call{value: amt2}("");
            require(s2, "Withdraw failed");
            emit Withdrawn(msg.sender, roundIndex, scaleFactor, amt2);
            return;
        }

        // Check if user is a winner
        bool isWinner = false;
        bool tie = (g.winners.length == 2);
        uint16 w0 = (g.winners.length > 0) ? g.winners[0] : 0;
        uint16 w1 = (g.winners.length > 1) ? g.winners[1] : 0;
        if (guess == w0 || (tie && guess == w1)) {
            isWinner = true;
        }

        ub.claimed = true;

        if (!isWinner) {
            // loser gets nothing, just mark claimed
            return;
        }

        // winner payout
        if (!g.commissionTaken) {
            g.commissionTaken = true;
            uint256 commission = (g.totalPool * COMMISSION_PERCENT) / 100;
            (bool sc, ) = owner.call{value: commission}("");
            // ignoring failures for simplicity
        }

        uint256 payout = 0;
        if (!tie) {
            // single winner
            payout = g.winnerShareSingle;
        } else {
            // two winners
            // first claimer gets g.winnerShareDouble
            // second winner also claims g.winnerShareDouble
            // (We don't bother about remainder now, simplicity)
            payout = g.winnerShareDouble;
        }

        (bool sw, ) = msg.sender.call{value: payout}("");
        require(sw, "Payout failed");
        emit Claimed(msg.sender, roundIndex, scaleFactor, payout);
    }

    fallback() external payable {
        revert("No fallback");
    }
}
