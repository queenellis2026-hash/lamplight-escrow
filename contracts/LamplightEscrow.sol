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
///      payer is refunded after the deadline. No arbitrator in v1 — that is
///      a stated limitation, not an oversight (see README).
///   2. Payment splitting — one incoming USDC payment split across up to 5
///      recipients in a single transaction, by basis points.
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
///   pulls it later with `withdraw()`. A payout never reverts the
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
///   "Reentrant call", "Invalid payee", "Zero payment", "Invalid deadline",
///   "Escrow not found", "Only payee", "Only payer", "Already settled",
///   "Already delivered", "Empty work hash", "Deadline passed", "Not delivered",
///   "Deadline not reached", "Review period not ended", "Payment failed",
///   "Nothing to withdraw", "Insufficient gas for payout",
///   "Invalid recipient count", "Length mismatch", "Zero recipient",
///   "Invalid share", "Invalid shares total", and "Use createEscrow or splitPayment".
///   Solidity's checked arithmetic also retains its standard panic behavior.
contract LamplightEscrow {
    struct Escrow {
        address payer;
        address payee;
        uint256 amount;
        uint256 deadline;
        bytes32 workHash;
        bool delivered;
        uint256 deliveredAt;
        bool settled;
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

    /// @dev Extra gas required above the 63/64-rule minimum in _payOrCredit,
    ///   covering the gas check itself so the full PAYOUT_GAS_LIMIT is
    ///   actually forwarded.
    uint256 private constant PAYOUT_GAS_BUFFER = 5_000;

    event EscrowCreated(
        uint256 indexed id,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint256 deadline
    );
    event Delivered(uint256 indexed id, bytes32 workHash);
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
    /// @param payee Recipient entitled to deliver work and receive a released payment.
    /// @param deadline Earliest timestamp for a refund if work has not been delivered.
    /// @return id The newly created escrow identifier, starting at zero.
    function createEscrow(address payee, uint256 deadline) external payable returns (uint256 id) {
        require(payee != address(0) && payee != msg.sender, "Invalid payee");
        require(msg.value > 0, "Zero payment");
        require(deadline > block.timestamp, "Invalid deadline");

        id = nextEscrowId;
        escrows[id] = Escrow({
            payer: msg.sender,
            payee: payee,
            amount: msg.value,
            deadline: deadline,
            workHash: bytes32(0),
            delivered: false,
            deliveredAt: 0,
            settled: false
        });
        nextEscrowId = id + 1;
        emit EscrowCreated(id, msg.sender, payee, msg.value, deadline);
    }

    /// @notice Record delivery once, as the payee of an unsettled escrow,
    ///   before its deadline.
    /// @dev A delivery at or after the deadline reverts: without this, a
    ///   payee could deliver a junk hash as the deadline passes and kill
    ///   the payer's refund.
    /// @param id Existing escrow identifier.
    /// @param workHash Nonzero commitment to the delivered work.
    function deliver(uint256 id, bytes32 workHash) external {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payee, "Only payee");
        require(!escrow.settled, "Already settled");
        require(!escrow.delivered, "Already delivered");
        require(block.timestamp < escrow.deadline, "Deadline passed");
        require(workHash != bytes32(0), "Empty work hash");

        escrow.delivered = true;
        escrow.deliveredAt = block.timestamp;
        escrow.workHash = workHash;
        emit Delivered(id, workHash);
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
        require(escrow.delivered, "Not delivered");

        escrow.settled = true;
        _payOrCredit(escrow.payee, escrow.amount);
        emit Released(id, escrow.payee, escrow.amount);
    }

    /// @notice Refund an undelivered escrow to its payer at or after its deadline.
    /// @dev A failed payout credits the payer for withdrawal; the escrow remains settled.
    /// @param id Existing, undelivered, unsettled escrow identifier.
    function refund(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
        require(!escrow.settled, "Already settled");
        require(!escrow.delivered, "Already delivered");
        require(block.timestamp >= escrow.deadline, "Deadline not reached");

        escrow.settled = true;
        _payOrCredit(escrow.payer, escrow.amount);
        emit Refunded(id, escrow.payer, escrow.amount);
    }

    /// @notice Withdraw all pending credits to the caller.
    /// @dev A failed payment reverts, preserving the caller's credit for a later attempt.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Payment failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Read an escrow; nonexistent identifiers return the zero-valued struct.
    /// @param id Escrow identifier to read.
    /// @return The escrow's complete stored fields.
    function getEscrow(uint256 id) external view returns (Escrow memory) {
        return escrows[id];
    }

    /// @notice Split this call's native payment among one to five recipients, crediting failed payouts.
    /// @dev Shares must total 10,000 basis points. The last recipient receives all rounding dust.
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
        for (uint256 i = 0; i < count; ++i) {
            require(recipients[i] != address(0), "Zero recipient");
            require(sharesBps[i] <= 10000, "Invalid share");
            totalShares += sharesBps[i];
        }
        require(totalShares == 10000, "Invalid shares total");

        uint256 paid;
        for (uint256 i = 0; i < count; ++i) {
            // Quotient/remainder decomposition equals floor(value * share / 10000)
            // without overflowing the intermediate product for large native values.
            uint256 amount = i == count - 1
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
    function _payOrCredit(address to, uint256 amount) internal {
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
