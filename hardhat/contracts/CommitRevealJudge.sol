// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title CommitRevealJudge
/// @notice Two-phase commit-then-reveal variant of the AI bounty judge.
///         During the commit phase, submitters register only keccak256(answer, salt, sender, bountyId).
///         Plaintext answers are revealed and verified only after the commit deadline.
///         Unrevealed submissions cannot be selected as winners.
/// @dev Layout uses a single dynamic `entries` array per bounty. Each entry is a fixed-size
///      struct so the bounty struct itself stays in a single storage slot for cheap lookups.
contract CommitRevealJudge is PrecompileConsumer {
    // ----- constants -----
    uint256 public constant MAX_ENTRIES = 10;
    uint256 public constant MAX_TEXT_BYTES = 2_000;
    uint256 public constant SALT_BYTES = 32;

    // ----- types -----
    struct Entry {
        address who;          // submitter (address(0) until reveal)
        bytes32 hash;         // commitment hash, set at commit time
        string  answer;       // empty until reveal
        bool    revealed;
        bool    cancelled;    // true if reveal failed verification
    }

    struct Bounty {
        address owner;
        string  title;
        string  rubric;
        uint256 reward;
        uint256 commitDeadline;  // commit phase ends at this timestamp
        uint256 revealDeadline;  // reveal phase window
        bool    committed;       // any commit recorded
        bool    judged;
        bool    finalized;
        uint256 winnerIndex;
        bytes   aiReview;
        Entry[] entries;
    }

    // ----- state -----
    uint256 public nextId = 1;
    mapping(uint256 => Bounty) private _bounties;

    // Per-bounty per-submitter commit hash (set at commit, cleared after reveal)
    mapping(uint256 => mapping(address => bytes32)) private _committedHash;
    mapping(uint256 => mapping(address => bool))    private _hasCommitted;

    // ----- events -----
    event BountyOpened(uint256 indexed id, address indexed owner, string title, uint256 reward, uint256 commitDeadline, uint256 revealDeadline);
    event Committed   (uint256 indexed id, address indexed who, bytes32 hash, uint256 index);
    event Revealed    (uint256 indexed id, address indexed who, uint256 index);
    event RevealFailed(uint256 indexed id, address indexed who, uint256 index);
    event Judged      (uint256 indexed id, bytes aiReview);
    event Finalized   (uint256 indexed id, uint256 winnerIndex, address winner, uint256 payout);

    // ----- errors -----
    error NotOwner();
    error UnknownBounty();
    error BadDeadlineOrder();
    error NoReward();
    error PhaseClosed();
    error WrongPhase();
    error AlreadyCommitted();
    error NoCommitment();
    error AnswerTooLong();
    error TooManyEntries();
    error AlreadyJudged();
    error NotJudgedYet();
    error AlreadyFinal();
    error NoEntries();
    error BadIndex();
    error HashMismatch();
    error PayFail();

    modifier onlyOwnerOf(uint256 id) {
        Bounty storage b = _bounties[id];
        if (b.owner == address(0)) revert UnknownBounty();
        if (msg.sender != b.owner) revert NotOwner();
        _;
    }

    // ===== owner flow =====

    function openBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 id) {
        if (msg.value == 0) revert NoReward();
        if (commitDeadline <= block.timestamp) revert BadDeadlineOrder();
        if (revealDeadline <= commitDeadline) revert BadDeadlineOrder();

        id = nextId++;
        Bounty storage b = _bounties[id];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.commitDeadline = commitDeadline;
        b.revealDeadline = revealDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyOpened(id, msg.sender, title, msg.value, commitDeadline, revealDeadline);
    }

    // ===== commit phase =====

    function commit(uint256 id, bytes32 hash) external {
        Bounty storage b = _bounties[id];
        if (b.owner == address(0)) revert UnknownBounty();
        if (b.judged || b.finalized) revert AlreadyJudged();
        if (block.timestamp >= b.commitDeadline) revert PhaseClosed();
        if (hash == bytes32(0)) revert NoCommitment();
        if (_hasCommitted[id][msg.sender]) revert AlreadyCommitted();
        if (b.entries.length >= MAX_ENTRIES) revert TooManyEntries();

        _committedHash[id][msg.sender] = hash;
        _hasCommitted[id][msg.sender] = true;

        // Push an entry with masked submitter. Reveal replaces who + fills answer.
        b.entries.push(Entry({
            who: address(0),
            hash: hash,
            answer: "",
            revealed: false,
            cancelled: false
        }));

        emit Committed(id, msg.sender, hash, b.entries.length - 1);
    }

    // ===== reveal phase =====

    function reveal(uint256 id, string calldata answer, bytes32 salt) external {
        Bounty storage b = _bounties[id];
        if (b.owner == address(0)) revert UnknownBounty();
        if (b.judged || b.finalized) revert AlreadyJudged();
        if (block.timestamp < b.commitDeadline) revert WrongPhase();
        if (block.timestamp >= b.revealDeadline) revert PhaseClosed();
        if (!_hasCommitted[id][msg.sender]) revert NoCommitment();
        if (bytes(answer).length > MAX_TEXT_BYTES) revert AnswerTooLong();

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, id));
        bytes32 stored = _committedHash[id][msg.sender];
        if (expected != stored) revert HashMismatch();

        // Locate the matching entry (latest entry with this hash + zero submitter)
        uint256 found = type(uint256).max;
        for (uint256 i = b.entries.length; i > 0; --i) {
            Entry storage candidate = b.entries[i - 1];
            if (!candidate.revealed && !candidate.cancelled && candidate.who == address(0) && candidate.hash == stored) {
                found = i - 1;
                break;
            }
        }
        if (found == type(uint256).max) {
            emit RevealFailed(id, msg.sender, 0);
            return;
        }

        Entry storage target = b.entries[found];
        target.who = msg.sender;
        target.answer = answer;
        target.revealed = true;

        // clear commitment state to prevent double-reveal
        _committedHash[id][msg.sender] = bytes32(0);

        emit Revealed(id, msg.sender, found);
    }

    // ===== judge + finalize =====

    function judge(uint256 id, bytes calldata llmInput) external onlyOwnerOf(id) {
        Bounty storage b = _bounties[id];
        if (b.judged) revert AlreadyJudged();
        if (b.finalized) revert AlreadyFinal();
        if (b.entries.length == 0) revert NoEntries();
        if (block.timestamp < b.revealDeadline) revert WrongPhase();

        // Use precompile. Caller passes llmInput that targeted revealed entries only.
        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
        // output is (bool hasError, bytes completionData, bytes modelMeta, string errMsg, ...)
        (bool hasError, bytes memory completionData,, string memory errMsg) =
            abi.decode(output, (bool, bytes, bytes, string));

        if (hasError) revert(errMsg);

        b.judged = true;
        b.aiReview = completionData;
        emit Judged(id, completionData);
    }

    function finalize(uint256 id, uint256 winnerIndex) external onlyOwnerOf(id) {
        Bounty storage b = _bounties[id];
        if (!b.judged) revert NotJudgedYet();
        if (b.finalized) revert AlreadyFinal();
        if (winnerIndex >= b.entries.length) revert BadIndex();

        Entry storage win = b.entries[winnerIndex];
        if (!win.revealed) revert BadIndex(); // can't pick an unrevealed entry as winner

        b.finalized = true;
        b.winnerIndex = winnerIndex;

        uint256 payout = b.reward;
        b.reward = 0;
        (bool ok,) = payable(win.who).call{value: payout}("");
        if (!ok) revert PayFail();

        emit Finalized(id, winnerIndex, win.who, payout);
    }

    // ===== views =====

    function getBounty(uint256 id) external view returns (
        address owner,
        string memory title,
        string memory rubric,
        uint256 reward,
        uint256 commitDeadline,
        uint256 revealDeadline,
        bool judged,
        bool finalized,
        uint256 entryCount,
        uint256 winnerIndex,
        bytes memory aiReview
    ) {
        Bounty storage b = _bounties[id];
        if (b.owner == address(0)) revert UnknownBounty();
        return (
            b.owner, b.title, b.rubric, b.reward,
            b.commitDeadline, b.revealDeadline,
            b.judged, b.finalized, b.entries.length, b.winnerIndex, b.aiReview
        );
    }

    /// Returns submitter + revealed answer. Empty string + zero address until reveal.
    function getEntry(uint256 id, uint256 idx) external view returns (address who, string memory answer, bool revealed) {
        Bounty storage b = _bounties[id];
        if (b.owner == address(0)) revert UnknownBounty();
        if (idx >= b.entries.length) revert BadIndex();
        Entry storage e = b.entries[idx];
        if (!e.revealed) return (address(0), "", false);
        return (e.who, e.answer, true);
    }

    /// Number of revealed entries at time of query.
    function revealedCount(uint256 id) external view returns (uint256 n) {
        Bounty storage b = _bounties[id];
        for (uint256 i = 0; i < b.entries.length; ++i) {
            if (b.entries[i].revealed) n++;
        }
    }

    /// Returns the commitment hash recorded for msg.sender (zero if none/already revealed).
    function myCommit(uint256 id) external view returns (bytes32) {
        return _committedHash[id][msg.sender];
    }
}
