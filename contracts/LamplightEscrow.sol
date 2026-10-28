// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Lamplight Escrow — pay-on-delivery escrow for AI agents on Arc
/// @author Ellis Lamplight (ellislamplight) — built for the DoraHacks Arc Microgrants
/// @notice One contract, two of the Microgrants' suggested tracks:
///   1. Escrow / conditional payouts — a payer locks native USDC for a named
///      agent (payee). The payee marks delivery on-chain with a hash of the
///      work, and must do so before the deadline: a delivery at or after the
///      deadline reverts, so a payee can never front-run the payer's refund
///      with a junk hash. The payer releases during a 7-day review window
///      after delivery; if the payer stays silent past the window, the payee
///      may release and claim the funds. If delivery never happens, the
///      payer is refunded after the deadline. If the payer rejects a
///      delivery inside the review window, the payee has a bounded cure
///      window to re-deliver a corrected hash — even past the deadline —
///      and only inside that window; if it does not cure in time, the
///      payer may refund via refundAfterRejection(). A rejected escrow
///      can never take the plain refund() path, so a payer cannot reject
///      a valid delivery after the deadline and refund immediately. A
///      rejection may happen at most ONCE per escrow: a second rejection
///      reverts, so a payer cannot reject every cured delivery in turn.
///      The payer may also extend an undelivered escrow's deadline once,
///      by at most 7 days, before delivery. V2 adds an OPTIONAL
///      per-escrow arbiter (see createEscrow): at creation the payer may
///      name a third-party arbiter — address(0) means none, and the flow
///      is exactly v1's. After the payee cures a rejected delivery, the
///      payer may escalate the disputed cure to the arbiter instead of
///      waiting out the review window; the arbiter decides release or
///      refund, and while escalated neither party can release. The
///      arbiter check only compares addresses — it cannot prove the
///      arbiter is independent — so the payee should read the arbiter
///      before accepting work and only take escrows whose arbiter it
///      trusts (see README).
///      Round 2 (Oct 27, 2026) hardens the arbiter path in five ways:
///      (1) an arbiter timeout — after 14 days escalated, either party
///      may force-refund the payer, so a silent arbiter can no longer
///      stall an escrow forever; (2) the EscrowCreated event now
///      carries the arbiter, backup arbiter, and bond amount, so
///      indexers and UIs need no second call; (3) an invariant that
///      while escalated, neither release nor any refund can succeed;
///      (4) an OPTIONAL arbiter bond — set at creation, staked by the
///      arbiter in a separate payable call before escalation, refunded
///      to the arbiter on every settlement, forfeited to the payer only
///      when the arbiter it was staked against times out (a backup
///      arbiter's silence forfeits nothing: the primary arbiter acted,
///      and the backup staked nothing); (5) an optional backup arbiter
///      — after the primary arbiter resolves, a 2-day challenge window
///      opens in which either party may re-escalate to the backup
///      arbiter for one final decision; if nobody challenges, the
///      resolution stands and anyone may finalize it. The payout is
///      deferred while the challenge window is open, so a reversed
///      decision never has to claw funds back.
///   2. Payment splitting — one incoming USDC payment split across up to 5
///      recipients in a single transaction, by basis points.
/// @dev Storage is packed: the Escrow struct fits in 7 slots (was 8 in
///   the first draft, 4 in v1 rounds 5-9, 5 in v2 round 1) —
///   amount is uint96, deadline / deliveredAt / rejectedAt are uint40,
///   and "delivered" is deliveredAt != 0 rather than a separate bool.
///   rejectedOnce caps rejections at one per escrow, deadlineExtended
///   caps the deadline extension at one use. V2 adds `escalated` and
///   `challengeOpen` (bools in slot 2, now 221 of 256 bits) and
///   `arbiter` (slot 4); round 2 adds `backupArbiter` + `bondAmount`
///   (slot 5, 160 + 96 = 256 bits exactly) and `escalatedAt` /
///   `resolvedAt` / `resolvedToPayee` / `bondStaked` / `challenged`
///   (slot 6, 83 bits). `challengeOpen` sits in slot 2 deliberately:
///   release() already reads slot 2, so the challenge guard costs no
///   extra cold SLOAD before the payout gas check.
///   Amounts above 2**96 wei
///   (~7.9e10 native token) revert in createEscrow; a deadline past
///   2**40 seconds (~year 34828) is likewise rejected. Timestamps are
///   uint40 because no escrow deadline can ever approach 2**40 seconds.
///   Rejection state is rejectedAt != 0; a cured re-delivery clears it
///   (rejectedOnce stays set).
/// @dev Arc note: on Arc, USDC is the NATIVE token — it is the gas token and
///   it arrives in a contract as msg.value, exactly the way ETH arrives on
///   Ethereum. There is no ERC-20 transfer in this contract. Amounts are in
///   the native token's smallest unit; this contract is decimal-agnostic.
///   Arc documentation describes native USDC as 18 decimals (unlike the
///   6-decimal ERC-20 USDC on other chains); the front-end formats with 18
///   decimals and flags that as a display assumption only.
/// @dev Payouts are PULL payments. release / refund / splitPayment first try
///   a direct payout capped at 100,000 gas; if that fails — the recipient is
///   a contract that reverts, or one that burns more gas than the cap — the
///   amount is credited to `pendingWithdrawals` instead and the recipient
///   pulls it later with `withdraw()`, or to a different address with
///   `withdrawTo()` (added Oct 27, 2026: a credit to a contract with no
///   payable receive() can never be pulled to itself, so withdrawTo() is
///   the only recovery path). A payout never reverts the
///   settlement, so a broken payee can never grief-block a release.
/// @dev REVISED after independent review (Oct 27, 2026): this file NO LONGER
///   matches the Arc Studio build. The review found that deliver() had no
///   deadline check (a payee could front-run a refund with a junk hash), that
///   a silent payer could lock the funds forever, that zero-share recipients
///   got a pointless call, and that a caller could force a credit with a low
///   gas limit. This revision adds the deadline check, the 7-day review
///   window, the zero-amount skip, and the payout gas check. Studio must be
///   updated and re-verified to match before the mainnet deploy (Studio
///   project https://studio.arc.io/app/16fcd6f7-5614-4e37-aee6-ad6575f83d73;
///   pre-revision reference copy at studio-contract-reference.sol).
///   Revert strings are used consistently for validation and failed withdrawals:
///   "Reentrant call", "Invalid payee", "Invalid arbiter", "Zero payment", "Amount too large",
///   "Invalid deadline", "Invalid extension", "Deadline already extended",
///   "Escrow not found", "Only payee", "Only payer", "Only arbiter",
///   "Only backup arbiter", "Only party",
///   "Already settled", "Already delivered", "Already rejected",
///   "Already escalated", "Already challenged", "Empty work hash", "Deadline passed",
///   "Not delivered", "Not rejected", "Not resolved",
///   "Not cured", "Not escalated", "No arbiter", "No backup arbiter", "Disputed",
///   "Resolution pending", "Bond not staked", "No bond set",
///   "Wrong bond amount", "Bond already staked", "Invalid backup arbiter",
///   "Arbiter timeout not reached", "Challenge period ended",
///   "Challenge period not ended",
///   "Deadline not reached", "Review period not ended", "Review period ended",
///   "Cure period not ended", "Cure period ended", "Payment failed",
///   "Nothing to withdraw",
///   "Insufficient gas for payout", "Invalid recipient count",
///   "Length mismatch", "Zero recipient", "Invalid recipient",
///   "Invalid share", "Invalid shares total", and "Use createEscrow or splitPayment".
///   Solidity's checked arithmetic also retains its standard panic behavior.
contract LamplightEscrow {
    struct Escrow {
        address payer; // slot 0
        address payee; // slot 1
        // slot 2 (221 of 256 bits): amount + deadline + deliveredAt +
        //   rejectedAt + settled + rejectedOnce + deadlineExtended +
        //   escalated + challengeOpen.
        // delivered == (deliveredAt != 0); there is no separate bool.
        uint96 amount;
        uint40 deadline;
        uint40 deliveredAt;
        uint40 rejectedAt;
        bool settled;
        bool rejectedOnce; // a rejection already happened; caps rejections at one
        bool deadlineExtended; // the one-time deadline extension was used
        bool escalated; // the payer escalated a disputed cure to the arbiter
        bool challengeOpen; // the arbiter resolved and the challenge window is open
        bytes32 workHash; // slot 3
        address arbiter; // slot 4: optional third-party arbiter, address(0) = none
        // slot 5 (256 of 256 bits): backup arbiter + bond amount.
        address backupArbiter; // optional second arbiter for a post-resolution challenge
        uint96 bondAmount; // optional arbiter bond, 0 = no bond
        // slot 6 (83 of 256 bits): dispute clocks and flags.
        uint40 escalatedAt; // when the dispute was (re-)escalated; arbiter-timeout clock
        uint40 resolvedAt; // when the arbiter resolved; challenge-window clock
        bool resolvedToPayee; // the arbiter's recorded decision, pending finalization
        bool bondStaked; // the arbiter posted the bond
        bool challenged; // re-escalated to the backup arbiter
    }

    /// @dev The escrows mapping is internal, not public: with 19 struct
    ///   fields, Solidity's auto-generated public getter cannot compile
    ///   (solc "stack too deep" in the tuple ABI encoding). getEscrow()
    ///   below is the read path and returns the same struct.
    mapping(uint256 => Escrow) internal escrows;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public nextEscrowId;
    bool private entered;

    /// @dev Gas forwarded to a recipient on push payouts. A recipient needing more is
    /// credited instead and can pull via withdraw(), so it can never stall settlement.
    uint256 private constant PAYOUT_GAS_LIMIT = 100_000;

    /// @dev Review window after delivery: the payer alone may release during
    ///   it; after it ends the payee may also release, so a silent payer
    ///   cannot lock the funds forever.
    uint256 public constant REVIEW_PERIOD = 7 days;

    /// @dev Cure window after a payer rejects a delivery: the payee has
    ///   this long to re-deliver a corrected hash (before the escrow
    ///   deadline, as always). If it does not cure in time, the payer may
    ///   refund via refundAfterRejection(). The cure window EQUALS the
    ///   review window (REVIEW_PERIOD, 7 days) — deliberately: with a
    ///   shorter cure a payer could reject at deliveredAt + 7d - 1s and
    ///   win by default if the payee was offline for the cure, so the
    ///   cure must last as long as the review the rejection came from
    ///   (round 6, Oct 27, 2026, Claude Medium).
    uint256 public constant REJECT_CURE_PERIOD = REVIEW_PERIOD;

    /// @dev Extra gas required above the 63/64-rule minimum in _payOrCredit.
    ///   The 63/64 cap is applied AFTER the CALL's own base cost is charged
    ///   (2,600 cold account + 9,000 value transfer + 25,000 if the target
    ///   account is empty — up to 36,600 worst case), so a small buffer does
    ///   not actually guarantee the full PAYOUT_GAS_LIMIT is forwarded: with
    ///   a 5,000 buffer a caller could tune the gas limit so a payee whose
    ///   receive() costs ~97k gas was credited instead of paid directly.
    ///   40,000 covers the worst-case CALL base cost with margin.
    uint256 private constant PAYOUT_GAS_BUFFER = 40_000;

    /// @dev Max one-time deadline extension (see extendDeadline): 7 days.
    ///   Bounded and once-only so an extension can never reopen the
    ///   front-run hole the deadline rule closes — it cannot be called
    ///   after delivery or at/after the deadline, and the increase is capped.
    uint256 public constant MAX_DEADLINE_EXTENSION = 7 days;

    /// @dev Arbiter timeout (round 2, Oct 27, 2026): after this long
    ///   escalated with no resolution, either party may force-refund the
    ///   payer via resolveDisputeTimeout(). 14 days is twice the review
    ///   window — long enough that a merely slow arbiter is never cut
    ///   off, short enough that a silent one cannot stall an escrow
    ///   indefinitely. The clock restarts if the dispute is re-escalated
    ///   to the backup arbiter.
    uint256 public constant ARBITER_TIMEOUT = 14 days;

    /// @dev Post-resolution challenge window (round 2, Oct 27, 2026):
    ///   after the primary arbiter resolves, either party has this long
    ///   to re-escalate to the backup arbiter. 2 days — shorter than the
    ///   7-day review window, long enough for a party watching the
    ///   escrow to react. Only applies when a backup arbiter was named.
    uint256 public constant CHALLENGE_PERIOD = 2 days;

    event EscrowCreated(
        uint256 indexed id,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint256 deadline,
        address arbiter,
        address backupArbiter,
        uint256 bondAmount
    );
    event Delivered(uint256 indexed id, bytes32 workHash);
    event DeliveryRejected(uint256 indexed id, address indexed payer, bytes32 rejectedWorkHash);
    event DisputeEscalated(uint256 indexed id, address indexed payer, address indexed arbiter);
    event DisputeResolved(uint256 indexed id, address indexed arbiter, bool releasedToPayee);
    event DisputeTimedOut(uint256 indexed id, address indexed caller);
    event DisputeChallenged(uint256 indexed id, address indexed challenger, address indexed backupArbiter);
    event BondStaked(uint256 indexed id, address indexed arbiter, uint256 amount);
    event BondReturned(uint256 indexed id, address indexed arbiter, uint256 amount);
    event BondForfeited(uint256 indexed id, address indexed payer, uint256 amount);
    event DeadlineExtended(uint256 indexed id, uint256 newDeadline);
    event Released(uint256 indexed id, address indexed payee, uint256 amount);
    event Refunded(uint256 indexed id, address indexed payer, uint256 amount);
    event SplitPaid(address indexed payer, uint256 total, uint256 recipientCount);
    event Credited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    modifier nonReentrant() {
        require(!entered, "Reentrant call");
        entered = true;
        _;
        entered = false;
    }

    /// @notice Fund an escrow for a distinct, nonzero payee and a future deadline.
    /// @dev Amounts above 2**96 wei revert ("Amount too large"); deadlines
    ///   past 2**40 seconds revert as "Invalid deadline". Both bounds are
    ///   far above any real escrow and exist only so the packed struct
    ///   can never truncate a value. No arbiter: the flow is exactly v1's.
    /// @param payee Recipient entitled to deliver work and receive a released payment.
    /// @param deadline Earliest timestamp for a refund if work has not been delivered.
    /// @return id The newly created escrow identifier, starting at zero.
    function createEscrow(address payee, uint256 deadline) external payable returns (uint256 id) {
        return _createEscrow(payee, deadline, address(0), address(0), 0);
    }

    /// @notice Fund an escrow with an optional third-party arbiter.
    /// @dev The arbiter overload of createEscrow: same as the two-argument
    ///   version, plus an arbiter the payer may escalate a disputed cure
    ///   to (see escalateDispute). The arbiter must be a third party —
    ///   not the payer, not the payee, not this contract — but the check
    ///   only compares addresses and cannot prove independence, so the
    ///   payee should read the arbiter before accepting work.
    /// @param payee Recipient entitled to deliver work and receive a released payment.
    /// @param deadline Earliest timestamp for a refund if work has not been delivered.
    /// @param arbiter Third-party arbiter for disputed cures, or address(0) for none.
    /// @return id The newly created escrow identifier, starting at zero.
    function createEscrow(address payee, uint256 deadline, address arbiter)
        external
        payable
        returns (uint256 id)
    {
        return _createEscrow(payee, deadline, arbiter, address(0), 0);
    }

    /// @notice Fund an escrow with an arbiter, an optional backup arbiter,
    ///   and an optional arbiter bond.
    /// @dev The full round-2 overload: same as the three-argument version,
    ///   plus a backup arbiter the dispute may be re-escalated to after
    ///   the primary arbiter resolves (see reEscalate), and a bond amount
    ///   the arbiter must stake before escalation (see stakeBond).
    ///   The backup arbiter must be a third party like the arbiter, must
    ///   differ from the arbiter, and requires an arbiter to be set at
    ///   all; a nonzero bond likewise requires an arbiter. All three
    ///   arbiter terms are emitted in EscrowCreated so indexers and UIs
    ///   can surface them without a second call.
    /// @param payee Recipient entitled to deliver work and receive a released payment.
    /// @param deadline Earliest timestamp for a refund if work has not been delivered.
    /// @param arbiter Third-party arbiter for disputed cures, or address(0) for none.
    /// @param backupArbiter Second arbiter for a post-resolution challenge, or address(0) for none.
    /// @param bondAmount Optional bond the arbiter must stake before escalation (0 = no bond).
    /// @return id The newly created escrow identifier, starting at zero.
    function createEscrow(
        address payee,
        uint256 deadline,
        address arbiter,
        address backupArbiter,
        uint96 bondAmount
    ) external payable returns (uint256 id) {
        return _createEscrow(payee, deadline, arbiter, backupArbiter, bondAmount);
    }

    /// @dev Validate the arbiter terms of a new escrow. Split out of
    ///   _createEscrow so the boolean chains live in their own stack
    ///   frame (solc's "stack too deep" fires when they share the
    ///   creation frame with the storage writes).
    function _validateArbiterTerms(
        address payee,
        address arbiter,
        address backupArbiter,
        uint96 bondAmount
    ) internal view {
        require(
            arbiter == address(0) ||
                (arbiter != msg.sender && arbiter != payee && arbiter != address(this)),
            "Invalid arbiter"
        );
        require(
            backupArbiter == address(0) ||
                (arbiter != address(0) &&
                    backupArbiter != msg.sender &&
                    backupArbiter != payee &&
                    backupArbiter != address(this) &&
                    backupArbiter != arbiter),
            "Invalid backup arbiter"
        );
        require(bondAmount == 0 || arbiter != address(0), "No arbiter");
    }

    /// @dev Shared creation logic for all createEscrow overloads.
    function _createEscrow(
        address payee,
        uint256 deadline,
        address arbiter,
        address backupArbiter,
        uint96 bondAmount
    ) internal returns (uint256 id) {
        require(payee != address(0) && payee != msg.sender && payee != address(this), "Invalid payee");
        _validateArbiterTerms(payee, arbiter, backupArbiter, bondAmount);
        require(msg.value > 0, "Zero payment");
        require(msg.value <= type(uint96).max, "Amount too large");
        require(deadline > block.timestamp && deadline <= type(uint40).max, "Invalid deadline");

        id = nextEscrowId;
        // Field-by-field storage writes, not a struct literal: the
        // literal form hits solc's "stack too deep" with 19 fields.
        Escrow storage e = escrows[id];
        e.payer = msg.sender;
        e.payee = payee;
        e.amount = uint96(msg.value);
        e.deadline = uint40(deadline);
        e.arbiter = arbiter;
        e.backupArbiter = backupArbiter;
        e.bondAmount = bondAmount;
        nextEscrowId = id + 1;
        emit EscrowCreated(id, msg.sender, payee, msg.value, deadline, arbiter, backupArbiter, bondAmount);
    }

    /// @notice Record delivery once, as the payee of an unsettled escrow,
    ///   before its deadline — or, after a rejection, as a cure inside the
    ///   cure window even past the deadline.
    /// @dev A fresh delivery at or after the deadline reverts: without
    ///   this, a payee could deliver a junk hash as the deadline passes
    ///   and kill the payer's refund. A re-delivery after a rejection is
    ///   the cure: it clears the rejection and starts a fresh review
    ///   window. The cure is bounded by rejectedAt + REJECT_CURE_PERIOD,
    ///   NOT by the deadline — a rejected delivery's deadline has already
    ///   passed by definition in the case the cure exists for, so the
    ///   deadline must not gate it. After the cure window ends the
    ///   delivery is dead and the payer's refundAfterRejection is the
    ///   only exit; a late cure reverts so the payee can never front-run
    ///   that refund with a junk hash and a fresh review window.
    /// @param id Existing escrow identifier.
    /// @param workHash Nonzero commitment to the delivered work.
    function deliver(uint256 id, bytes32 workHash) external {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payee, "Only payee");
        require(!escrow.settled, "Already settled");
        require(escrow.deliveredAt == 0, "Already delivered");
        if (escrow.rejectedAt != 0) {
            require(
                block.timestamp < escrow.rejectedAt + REJECT_CURE_PERIOD,
                "Cure period ended"
            );
        } else {
            require(block.timestamp < escrow.deadline, "Deadline passed");
        }
        require(workHash != bytes32(0), "Empty work hash");

        escrow.deliveredAt = uint40(block.timestamp);
        escrow.rejectedAt = 0; // a cure clears the rejection (rejectedOnce stays set)
        escrow.workHash = workHash;
        emit Delivered(id, workHash);
    }

    /// @notice Reject a delivery inside the review window.
    /// @dev Only the payer, only while the delivery is still under review
    ///   (block.timestamp < deliveredAt + REVIEW_PERIOD). At the exact
    ///   boundary second the payee may already claim (release uses >=),
    ///   so a reject there reverts — the payee wins the boundary, mirroring
    ///   the release rule. A rejection clears the delivery (deliveredAt
    ///   and workHash go back to zero) and starts the cure clock: the
    ///   payee may re-deliver a corrected hash within REJECT_CURE_PERIOD
    ///   (even past the deadline); if it does not, the payer may refund
    ///   via refundAfterRejection(). The rejected hash is emitted in the
    ///   DeliveryRejected event, so off-chain parties can still prove
    ///   what was rejected after the clear (it also remains in the
    ///   earlier Delivered event's history). Rejections are capped at ONE
    ///   per escrow (rejectedOnce): a cured delivery cannot be rejected
    ///   again, so a payer cannot reject every cured delivery in turn and
    ///   the payee's cure is real protection, not a treadmill.
    /// @param id Existing, delivered, unsettled escrow identifier.
    function rejectDelivery(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(!escrow.rejectedOnce, "Already rejected");
        require(escrow.deliveredAt != 0, "Not delivered");
        require(block.timestamp < escrow.deliveredAt + REVIEW_PERIOD, "Review period ended");

        bytes32 rejectedHash = escrow.workHash;
        escrow.rejectedOnce = true;
        escrow.rejectedAt = uint40(block.timestamp);
        escrow.deliveredAt = 0;
        escrow.workHash = bytes32(0);
        emit DeliveryRejected(id, msg.sender, rejectedHash);
    }

    /// @notice Refund a rejected delivery the payee did not cure in time.
    /// @dev Only the payer, only after rejectedAt + REJECT_CURE_PERIOD,
    ///   only while the escrow is still undelivered (a cure re-delivery
    ///   clears the rejection, so this reverts with "Not rejected" once
    ///   cured). A failed payout credits the payer for withdrawal; the
    ///   escrow remains settled.
    /// @param id Existing, rejected, unsettled escrow identifier.
    function refundAfterRejection(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(escrow.rejectedAt != 0, "Not rejected");
        require(escrow.deliveredAt == 0, "Already delivered");
        require(block.timestamp >= escrow.rejectedAt + REJECT_CURE_PERIOD, "Cure period not ended");

        escrow.settled = true;
        _payOrCredit(escrow.payer, escrow.amount);
        emit Refunded(id, escrow.payer, escrow.amount);
        _settleBond(escrow, id, false);
    }

    /// @notice Stake the arbiter bond for an escrow that named one.
    /// @dev Only the escrow's arbiter, only the exact bond amount set at
    ///   creation, only once, and only before escalation — escalation
    ///   requires the bond when one was set, so a late stake is useless
    ///   after the dispute is already with the arbiter. The bond is held
    ///   by the contract until the escrow settles: it returns to the
    ///   arbiter on every settlement except an arbiter timeout, where it
    ///   is forfeited to the payer (see resolveDisputeTimeout). If the
    ///   escrow settles without any escalation — a normal release or
    ///   refund — the bond is returned to the arbiter too, so it can
    ///   never strand. A failed payout credits the arbiter for
    ///   withdrawal, like every other payout in this contract.
    /// @param id Existing, unsettled, un-escalated escrow identifier.
    function stakeBond(uint256 id) external payable nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.arbiter, "Only arbiter");
        require(!escrow.settled, "Already settled");
        require(!escrow.escalated, "Already escalated");
        require(escrow.bondAmount > 0, "No bond set");
        require(!escrow.bondStaked, "Bond already staked");
        require(msg.value == escrow.bondAmount, "Wrong bond amount");

        escrow.bondStaked = true;
        emit BondStaked(id, msg.sender, msg.value);
    }

    /// @notice Escalate a disputed cure to the escrow's arbiter.
    /// @dev Only the payer, only after the payee cured a rejected delivery
    ///   (rejectedOnce set and delivered again), only while the review
    ///   window is still open, and only when an arbiter was set at
    ///   creation. When a bond was set at creation, the arbiter must
    ///   have staked it first — an unstaked bond blocks escalation, so
    ///   the payer cannot escalate to an arbiter who has not put money
    ///   behind acting. While escalated, neither party can release — only
    ///   the arbiter resolves, or either party times it out after
    ///   ARBITER_TIMEOUT (see resolveDisputeTimeout). The arbiter is
    ///   whoever the payer named; the check cannot prove independence,
    ///   so the payee should have read the arbiter before accepting the
    ///   work.
    /// @param id Existing, delivered, unsettled escrow identifier.
    function escalateDispute(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(escrow.arbiter != address(0), "No arbiter");
        require(escrow.rejectedOnce, "Not rejected");
        require(escrow.deliveredAt != 0, "Not delivered");
        require(!escrow.escalated, "Already escalated");
        require(!escrow.challengeOpen, "Resolution pending");
        require(escrow.bondAmount == 0 || escrow.bondStaked, "Bond not staked");
        require(block.timestamp < escrow.deliveredAt + REVIEW_PERIOD, "Review period ended");

        escrow.escalated = true;
        escrow.escalatedAt = uint40(block.timestamp);
        emit DisputeEscalated(id, msg.sender, escrow.arbiter);
    }

    /// @notice Resolve an escalated dispute: release to the payee or refund the payer.
    /// @dev Only the escrow's arbiter — or, after a re-escalation, only
    ///   the backup arbiter — only while escalated, only once per
    ///   escalation. True pays the full amount to the payee; false
    ///   refunds the full amount to the payer. A failed payout credits
    ///   the recipient for withdrawal; the escrow remains settled.
    ///   When a backup arbiter was named, the FIRST resolution does NOT
    ///   pay out and does NOT settle: it records the decision and opens
    ///   the CHALLENGE_PERIOD window, so either party may re-escalate
    ///   to the backup arbiter (see reEscalate) and the payout is
    ///   deferred until the challenge is answered or the window closes
    ///   (see finalizeResolution). A resolution by the backup arbiter
    ///   is final — it pays out immediately and settles, with no
    ///   further challenge. The staked bond, if any, returns to the
    ///   arbiter on every resolution except a timeout forfeit.
    /// @param id Existing, escalated, unsettled escrow identifier.
    /// @param releaseToPayee True pays the payee; false refunds the payer.
    function resolveDispute(uint256 id, bool releaseToPayee) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        if (escrow.challenged) {
            require(msg.sender == escrow.backupArbiter, "Only backup arbiter");
        } else {
            require(msg.sender == escrow.arbiter, "Only arbiter");
        }
        require(!escrow.settled, "Already settled");
        require(escrow.escalated, "Not escalated");

        if (!escrow.challenged && escrow.backupArbiter != address(0)) {
            // First resolution with a backup arbiter named: record the
            // decision and open the challenge window instead of paying.
            // The bond stays staked until the challenge is answered or
            // the window closes and the resolution is finalized.
            escrow.escalated = false;
            escrow.challengeOpen = true;
            escrow.resolvedAt = uint40(block.timestamp);
            escrow.resolvedToPayee = releaseToPayee;
            emit DisputeResolved(id, msg.sender, releaseToPayee);
            return;
        }

        escrow.settled = true;
        escrow.escalated = false;
        escrow.challengeOpen = false;
        escrow.resolvedAt = 0;
        if (releaseToPayee) {
            _payOrCredit(escrow.payee, escrow.amount);
            emit Released(id, escrow.payee, escrow.amount);
        } else {
            _payOrCredit(escrow.payer, escrow.amount);
            emit Refunded(id, escrow.payer, escrow.amount);
        }
        _settleBond(escrow, id, false);
        emit DisputeResolved(id, msg.sender, releaseToPayee);
    }

    /// @notice Force-refund an escrow whose arbiter has been silent too long.
    /// @dev Either party — payer or payee — only while escalated, only
    ///   once ARBITER_TIMEOUT (14 days) has passed since the (re-)escalation.
    ///   The full escrow amount refunds to the payer and the escrow
    ///   settles; the arbiter can no longer resolve it. The bond is
    ///   forfeited to the payer when the SILENT arbiter is the one who
    ///   staked it — i.e. a timeout of the primary arbiter. If the
    ///   dispute was re-escalated and the BACKUP arbiter timed out, the
    ///   bond returns to the primary arbiter instead: it resolved in
    ///   time, the stall is the backup's fault, and the backup staked
    ///   nothing. A failed payout credits the recipient for withdrawal.
    /// @param id Existing, escalated, unsettled escrow identifier.
    function resolveDisputeTimeout(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer || msg.sender == escrow.payee, "Only party");
        require(!escrow.settled, "Already settled");
        require(escrow.escalated, "Not escalated");
        require(
            block.timestamp >= escrow.escalatedAt + ARBITER_TIMEOUT,
            "Arbiter timeout not reached"
        );

        bool forfeitBond = !escrow.challenged;
        escrow.settled = true;
        escrow.escalated = false;
        escrow.challengeOpen = false;
        escrow.resolvedAt = 0;
        _payOrCredit(escrow.payer, escrow.amount);
        emit Refunded(id, escrow.payer, escrow.amount);
        _settleBond(escrow, id, forfeitBond);
        emit DisputeTimedOut(id, msg.sender);
    }

    /// @notice Re-escalate a resolved dispute to the backup arbiter.
    /// @dev Either party — payer or payee — only inside the
    ///   CHALLENGE_PERIOD (2 days) after the primary arbiter resolved,
    ///   only when a backup arbiter was named at creation, and only
    ///   once: a second challenge reverts. Re-escalation re-opens the
    ///   dispute for the backup arbiter and restarts the arbiter-timeout
    ///   clock from now (see resolveDisputeTimeout). The backup
    ///   arbiter's resolution is final — no further challenge, no
    ///   further escalation. While re-escalated, release and refund
    ///   stay blocked exactly as while escalated.
    /// @param id Existing, resolved, unsettled escrow identifier.
    function reEscalate(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer || msg.sender == escrow.payee, "Only party");
        require(!escrow.settled, "Already settled");
        require(escrow.backupArbiter != address(0), "No backup arbiter");
        require(!escrow.challenged, "Already challenged");
        require(escrow.challengeOpen, "Not resolved");
        require(block.timestamp < escrow.resolvedAt + CHALLENGE_PERIOD, "Challenge period ended");

        escrow.challenged = true;
        escrow.escalated = true;
        escrow.challengeOpen = false;
        escrow.escalatedAt = uint40(block.timestamp);
        escrow.resolvedAt = 0;
        emit DisputeChallenged(id, msg.sender, escrow.backupArbiter);
    }

    /// @notice Finalize an unchallenged arbiter resolution after the challenge window closes.
    /// @dev Anyone may call it — finalization pays the recorded decision
    ///   to the recorded winner regardless of who triggers it, so there
    ///   is nothing to grief. Only when a resolution is pending
    ///   (challengeOpen) and the CHALLENGE_PERIOD has passed. The staked
    ///   bond, if any, returns to the arbiter. If a backup arbiter was
    ///   never named, resolveDispute pays out immediately and this
    ///   function is never needed.
    /// @param id Existing, resolved, unsettled escrow identifier.
    function finalizeResolution(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(!escrow.settled, "Already settled");
        require(escrow.challengeOpen, "Not resolved");
        require(
            block.timestamp >= escrow.resolvedAt + CHALLENGE_PERIOD,
            "Challenge period not ended"
        );

        bool releaseToPayee = escrow.resolvedToPayee;
        escrow.settled = true;
        escrow.challengeOpen = false;
        escrow.resolvedAt = 0;
        if (releaseToPayee) {
            _payOrCredit(escrow.payee, escrow.amount);
            emit Released(id, escrow.payee, escrow.amount);
        } else {
            _payOrCredit(escrow.payer, escrow.amount);
            emit Refunded(id, escrow.payer, escrow.amount);
        }
        _settleBond(escrow, id, false);
    }

    /// @notice Release the full delivered escrow amount to its payee.
    /// @dev The payer may release at any time after delivery. After the
    ///   7-day review window (deliveredAt + REVIEW_PERIOD), the payee may
    ///   also release, so a silent payer cannot lock the funds forever.
    ///   Before the window ends, only the payer can release. A failed
    ///   payout credits the payee for withdrawal; the escrow remains settled.
    ///   While a resolution is pending its challenge window, release is
    ///   blocked — the arbiter's recorded decision stands until it is
    ///   challenged or finalized. A staked bond returns to the arbiter.
    /// @param id Existing, delivered, unsettled escrow identifier.
    function release(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        if (msg.sender == escrow.payee) {
            require(
                block.timestamp >= escrow.deliveredAt + REVIEW_PERIOD,
                "Review period not ended"
            );
        } else {
            require(msg.sender == escrow.payer, "Only payer");
        }
        require(!escrow.settled, "Already settled");
        require(!escrow.escalated, "Disputed");
        require(!escrow.challengeOpen, "Resolution pending");
        require(escrow.deliveredAt != 0, "Not delivered");

        escrow.settled = true;
        _payOrCredit(escrow.payee, escrow.amount);
        emit Released(id, escrow.payee, escrow.amount);
        _settleBond(escrow, id, false);
    }

    /// @notice Refund an undelivered escrow to its payer at or after its deadline.
    /// @dev A failed payout credits the payer for withdrawal; the escrow remains settled.
    ///   A rejected escrow can NEVER take this path (rejectedAt != 0
    ///   reverts "Already rejected"): without this, a payer could reject
    ///   a valid delivery after the deadline — the rejection clears
    ///   deliveredAt — and refund immediately, taking back paid-for work
    ///   with no cure possible. Rejected escrows exit only through
    ///   refundAfterRejection(), after the cure window ends.
    /// @param id Existing, undelivered, unsettled escrow identifier.
    function refund(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(escrow.deliveredAt == 0, "Already delivered");
        require(escrow.rejectedAt == 0, "Already rejected");
        require(block.timestamp >= escrow.deadline, "Deadline not reached");

        escrow.settled = true;
        _payOrCredit(escrow.payer, escrow.amount);
        emit Refunded(id, escrow.payer, escrow.amount);
        _settleBond(escrow, id, false);
    }

    /// @notice Extend an undelivered escrow's deadline once, by at most 7 days.
    /// @dev Only the payer, only before delivery, only once, and only by a
    ///   bounded amount (MAX_DEADLINE_EXTENSION). It cannot reopen the
    ///   front-run hole: after delivery the deadline no longer gates
    ///   anything (a delivered escrow exits through release, never
    ///   refund), and the increase is capped so a payer cannot push the
    ///   deadline out indefinitely. It also cannot be used on a rejected
    ///   escrow — the cure window, not the deadline, is the binding clock
    ///   there — nor at or after the deadline: an expired escrow stays
    ///   expired, so a payer cannot revive it and let the payee deliver
    ///   again (round 6, Oct 27, 2026, Claude Low). The new deadline must
    ///   still fit the packed uint40 field.
    /// @param id Existing, undelivered, unsettled escrow identifier.
    /// @param extraSeconds Seconds to add to the deadline (1 .. 7 days).
    function extendDeadline(uint256 id, uint256 extraSeconds) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(escrow.deliveredAt == 0, "Already delivered");
        require(escrow.rejectedAt == 0, "Already rejected");
        require(block.timestamp < escrow.deadline, "Deadline passed");
        require(!escrow.deadlineExtended, "Deadline already extended");
        require(extraSeconds > 0 && extraSeconds <= MAX_DEADLINE_EXTENSION, "Invalid extension");
        uint256 newDeadline = uint256(escrow.deadline) + extraSeconds;
        require(newDeadline <= type(uint40).max, "Invalid deadline");

        escrow.deadline = uint40(newDeadline);
        escrow.deadlineExtended = true;
        emit DeadlineExtended(id, newDeadline);
    }

    /// @notice Withdraw all pending credits to the caller.
    /// @dev A failed payment reverts, preserving the caller's credit for a later attempt.
    function withdraw() external nonReentrant {
        _withdrawTo(msg.sender);
    }

    /// @notice Withdraw all pending credits to a chosen address.
    /// @dev Lets a credited party pull its credit to an address that can
    ///   receive it. Without this, a credit to a contract with no payable
    ///   receive() is stuck forever: withdraw() pays to the credited
    ///   address itself, which always reverts with "Payment failed".
    ///   Only the credited party may move its own credit.
    /// @param to Destination address; must be nonzero.
    function withdrawTo(address to) external nonReentrant {
        require(to != address(0), "Zero recipient");
        _withdrawTo(to);
    }

    /// @dev Shared withdraw logic: zero the credit first, then pay. A
    ///   failed payment reverts the whole call, so the credit is restored.
    function _withdrawTo(address to) internal {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Payment failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Read an escrow; nonexistent identifiers return the zero-valued struct.
    /// @param id Escrow identifier to read.
    /// @return The escrow's complete stored fields.
    function getEscrow(uint256 id) external view returns (Escrow memory) {
        return escrows[id];
    }

    /// @notice The lifecycle state of an escrow, as a single enum, so
    ///   front-ends and indexers never re-derive the state machine from
    ///   the three timestamps (deadline, deliveredAt, rejectedAt).
    ///   Nonexistent = no escrow at this id; Created = funded,
    ///   undelivered, deadline not yet reached; Expired = funded,
    ///   undelivered, deadline reached (payer may refund); InReview =
    ///   delivered, inside the review window; Claimable = delivered,
    ///   review window over (payee may claim); CureOpen = rejected,
    ///   cure window still open (payee may re-deliver); Rejected =
    ///   rejected, cure window over (payer may refundAfterRejection);
    ///   Settled = released or refunded. Escalated = delivered, cured,
    ///   and escalated to the arbiter (neither party can release; only
    ///   the arbiter resolves, or either party times it out after
    ///   ARBITER_TIMEOUT). ChallengeOpen = the arbiter resolved and the
    ///   challenge window is open (either party may re-escalate to the
    ///   backup arbiter, or the resolution is finalized once the window
    ///   closes; release stays blocked meanwhile).
    enum Lifecycle {
        Nonexistent,
        Created,
        Expired,
        InReview,
        Claimable,
        CureOpen,
        Rejected,
        Settled,
        Escalated,
        ChallengeOpen
    }

    /// @notice Read an escrow's lifecycle state.
    /// @dev Boundaries mirror the state-changing functions exactly:
    ///   InReview while block.timestamp < deliveredAt + REVIEW_PERIOD
    ///   (a reject there reverts; the payee may claim from the boundary),
    ///   CureOpen while block.timestamp < rejectedAt + REJECT_CURE_PERIOD
    ///   (a cure there reverts; the payer may refund from the boundary),
    ///   Expired from block.timestamp >= deadline (refund's rule).
    /// @param id Escrow identifier to read.
    /// @return The escrow's lifecycle state.
    function lifecycleStatus(uint256 id) external view returns (Lifecycle) {
        Escrow storage escrow = escrows[id];
        if (escrow.payer == address(0)) return Lifecycle.Nonexistent;
        if (escrow.settled) return Lifecycle.Settled;
        if (escrow.escalated) return Lifecycle.Escalated;
        if (escrow.challengeOpen) return Lifecycle.ChallengeOpen;
        if (escrow.rejectedAt != 0) {
            return block.timestamp < escrow.rejectedAt + REJECT_CURE_PERIOD
                ? Lifecycle.CureOpen
                : Lifecycle.Rejected;
        }
        if (escrow.deliveredAt != 0) {
            return block.timestamp < escrow.deliveredAt + REVIEW_PERIOD
                ? Lifecycle.InReview
                : Lifecycle.Claimable;
        }
        return block.timestamp < escrow.deadline ? Lifecycle.Created : Lifecycle.Expired;
    }

    /// @notice The two timestamps that bound the review window and the cure
    ///   window, so indexers and UIs never re-compute them.
    /// @dev reviewEnd is the last second of the review window: the payee
    ///   may claim from reviewEnd (release uses >=), and a reject at
    ///   reviewEnd reverts. cureEnd is the last second of the cure window:
    ///   the payee may cure before cureEnd, and the payer may refund after
    ///   it (>=). Both are 0 when they do not apply (not delivered / not
    ///   rejected), so a caller never mistakes an offset for a timestamp
    ///   that has already passed.
    /// @param id Escrow identifier to read.
    /// @return reviewEnd deliveredAt + REVIEW_PERIOD, or 0 if not delivered
    /// @return cureEnd rejectedAt + REJECT_CURE_PERIOD, or 0 if not rejected
    function reviewWindows(uint256 id) external view returns (uint256 reviewEnd, uint256 cureEnd) {
        Escrow storage escrow = escrows[id];
        reviewEnd = escrow.deliveredAt == 0 ? 0 : uint256(escrow.deliveredAt) + REVIEW_PERIOD;
        cureEnd = escrow.rejectedAt == 0 ? 0 : uint256(escrow.rejectedAt) + REJECT_CURE_PERIOD;
    }

    /// @notice Split this call's native payment among one to five recipients, crediting failed payouts.
    /// @dev Shares must total 10,000 basis points. The last recipient with a
    ///   nonzero share receives all rounding dust; a zero-share recipient
    ///   gets no call at all. The escrow contract itself can never be a
    ///   recipient: a credit to it could never be withdrawn.
    /// @param recipients Nonzero recipient addresses, in payment order.
    /// @param sharesBps Corresponding shares in basis points; zero shares are allowed.
    function splitPayment(address[] calldata recipients, uint256[] calldata sharesBps)
        external
        payable
        nonReentrant
    {
        require(msg.value > 0, "Zero payment");
        uint256 count = recipients.length;
        require(count >= 1 && count <= 5, "Invalid recipient count");
        require(count == sharesBps.length, "Length mismatch");

        uint256 totalShares;
        // lastNonZero is the index of the last recipient with a nonzero
        // share — the dust goes to it, never to a zero-share recipient.
        // There is always at least one nonzero share (totalShares == 10000),
        // so lastNonZero always exists.
        uint256 lastNonZero;
        for (uint256 i = 0; i < count; ++i) {
            require(recipients[i] != address(0), "Zero recipient");
            require(recipients[i] != address(this), "Invalid recipient");
            require(sharesBps[i] <= 10000, "Invalid share");
            totalShares += sharesBps[i];
            if (sharesBps[i] > 0) lastNonZero = i;
        }
        require(totalShares == 10000, "Invalid shares total");

        uint256 paid;
        for (uint256 i = 0; i < count; ++i) {
            // Quotient/remainder decomposition equals floor(value * share / 10000)
            // without overflowing the intermediate product for large native values.
            uint256 amount = i == lastNonZero
                ? msg.value - paid
                : (msg.value / 10000) * sharesBps[i]
                + ((msg.value % 10000) * sharesBps[i]) / 10000;
            paid += amount;
            // Zero-share recipients get no call at all: a 0-value call to a
            // reverting contract would emit a bogus Credited event, and to a
            // gas-burning one it would cost the payer up to the payout cap.
            if (amount > 0) {
                _payOrCredit(recipients[i], amount);
            }
        }
        emit SplitPaid(msg.sender, msg.value, count);
    }

    /// @dev Return a staked bond to the arbiter on settlement, or forfeit
    ///   it to the payer when the arbiter it was staked against timed
    ///   out. No-op when no bond was staked. A failed payout credits the
    ///   recipient for withdrawal, like every other payout here — so a
    ///   reverting arbiter's bond is never lost, only pullable.
    function _settleBond(Escrow storage escrow, uint256 id, bool forfeitToPayer) internal {
        if (!escrow.bondStaked) return;
        escrow.bondStaked = false;
        if (forfeitToPayer) {
            _payOrCredit(escrow.payer, escrow.bondAmount);
            emit BondForfeited(id, escrow.payer, escrow.bondAmount);
        } else {
            _payOrCredit(escrow.arbiter, escrow.bondAmount);
            emit BondReturned(id, escrow.arbiter, escrow.bondAmount);
        }
    }

    /// @dev Attempt a native-token payout, crediting the recipient if its call fails.
    /// @dev The caller must leave enough gas that the full PAYOUT_GAS_LIMIT is
    ///   actually forwarded. The EVM forwards at most 63/64 of the remaining
    ///   gas, so a caller with a low gas limit could otherwise force a credit
    ///   instead of a direct payout; this check makes that fail loudly
    ///   instead, and the caller must retry with enough gas.
    /// @dev A zero-value credit must never happen: a Credited event for 0
    ///   would confuse indexers and front-ends. Every public entry point
    ///   already enforces a nonzero amount (createEscrow / splitPayment
    ///   require value > 0, and splitPayment skips zero-share recipients
    ///   before calling), so this guard is defense in depth at the single
    ///   choke point all payouts funnel through (round 6, Oct 27, 2026,
    ///   Grok improvement); it cannot fire through a public call today.
    function _payOrCredit(address to, uint256 amount) internal {
        require(amount > 0, "Zero payment");
        require(
            gasleft() > (PAYOUT_GAS_LIMIT * 64) / 63 + PAYOUT_GAS_BUFFER,
            "Insufficient gas for payout"
        );
        (bool success, ) = to.call{value: amount, gas: PAYOUT_GAS_LIMIT}("");
        if (!success) {
            pendingWithdrawals[to] += amount;
            emit Credited(to, amount);
        }
    }

    /// @notice Reject plain native-token transfers; use an explicit payable entry point.
    receive() external payable {
        revert("Use createEscrow or splitPayment");
    }
}
