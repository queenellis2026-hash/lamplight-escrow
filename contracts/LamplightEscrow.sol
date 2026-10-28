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
///      by at most 7 days, before delivery. No third-party arbitrator in
///      v1 — that is a stated limitation, not an oversight (see README).
///   2. Payment splitting — one incoming USDC payment split across up to 5
///      recipients in a single transaction, by basis points.
/// @dev Storage is packed: the Escrow struct fits in 4 slots (was 8) —
///   amount is uint96, deadline / deliveredAt / rejectedAt are uint40,
///   and "delivered" is deliveredAt != 0 rather than a separate bool.
///   rejectedOnce caps rejections at one per escrow, deadlineExtended
///   caps the deadline extension at one use. Amounts above 2**96 wei
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
///   "Reentrant call", "Invalid payee", "Zero payment", "Amount too large",
///   "Invalid deadline", "Invalid extension", "Deadline already extended",
///   "Escrow not found", "Only payee", "Only payer",
///   "Already settled", "Already delivered", "Already rejected",
///   "Empty work hash", "Deadline passed", "Not delivered", "Not rejected",
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
        // slot 2 (240 of 256 bits): amount + deadline + deliveredAt +
        //   rejectedAt + settled + rejectedOnce + deadlineExtended.
        // delivered == (deliveredAt != 0); there is no separate bool.
        uint96 amount;
        uint40 deadline;
        uint40 deliveredAt;
        uint40 rejectedAt;
        bool settled;
        bool rejectedOnce; // a rejection already happened; caps rejections at one
        bool deadlineExtended; // the one-time deadline extension was used
        bytes32 workHash; // slot 3
    }

    mapping(uint256 => Escrow) public escrows;
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

    event EscrowCreated(
        uint256 indexed id,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint256 deadline
    );
    event Delivered(uint256 indexed id, bytes32 workHash);
    event DeliveryRejected(uint256 indexed id, address indexed payer, bytes32 rejectedWorkHash);
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
    ///   can never truncate a value.
    /// @param payee Recipient entitled to deliver work and receive a released payment.
    /// @param deadline Earliest timestamp for a refund if work has not been delivered.
    /// @return id The newly created escrow identifier, starting at zero.
    function createEscrow(address payee, uint256 deadline) external payable returns (uint256 id) {
        require(payee != address(0) && payee != msg.sender && payee != address(this), "Invalid payee");
        require(msg.value > 0, "Zero payment");
        require(msg.value <= type(uint96).max, "Amount too large");
        require(deadline > block.timestamp && deadline <= type(uint40).max, "Invalid deadline");

        id = nextEscrowId;
        escrows[id] = Escrow({
            payer: msg.sender,
            payee: payee,
            amount: uint96(msg.value),
            deadline: uint40(deadline),
            workHash: bytes32(0),
            deliveredAt: 0,
            settled: false,
            rejectedAt: 0,
            rejectedOnce: false,
            deadlineExtended: false
        });
        nextEscrowId = id + 1;
        emit EscrowCreated(id, msg.sender, payee, msg.value, deadline);
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
    }

    /// @notice Release the full delivered escrow amount to its payee.
    /// @dev The payer may release at any time after delivery. After the
    ///   7-day review window (deliveredAt + REVIEW_PERIOD), the payee may
    ///   also release, so a silent payer cannot lock the funds forever.
    ///   Before the window ends, only the payer can release. A failed
    ///   payout credits the payee for withdrawal; the escrow remains settled.
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
        require(escrow.deliveredAt != 0, "Not delivered");

        escrow.settled = true;
        _payOrCredit(escrow.payee, escrow.amount);
        emit Released(id, escrow.payee, escrow.amount);
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
    ///   Settled = released or refunded.
    enum Lifecycle {
        Nonexistent,
        Created,
        Expired,
        InReview,
        Claimable,
        CureOpen,
        Rejected,
        Settled
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
