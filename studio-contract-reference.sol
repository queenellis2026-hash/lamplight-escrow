// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LamplightEscrow
/// @notice Native-token escrow and payment splitting. On Arc, native USDC is supplied as msg.value.
/// @dev Failed payouts are credited for withdrawal instead of reverting settlement or splitting.
/// Revert strings are used consistently for validation and failed withdrawals:
/// "Reentrant call", "Invalid payee", "Zero payment", "Invalid deadline",
/// "Escrow not found", "Only payee", "Only payer", "Already settled",
/// "Already delivered", "Empty work hash", "Not delivered", "Deadline not reached",
/// "Payment failed", "Nothing to withdraw", "Invalid recipient count", "Length mismatch", "Zero recipient",
/// "Invalid share", "Invalid shares total", and "Use createEscrow or splitPayment".
/// Solidity's checked arithmetic also retains its standard panic behavior.
contract LamplightEscrow {
    struct Escrow {
        address payer;
        address payee;
        uint256 amount;
        uint256 deadline;
        bytes32 workHash;
        bool delivered;
        bool settled;
    }

    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public nextEscrowId;
    bool private entered;

    /// @dev Gas forwarded to a recipient on push payouts. A recipient needing more is
    /// credited instead and can pull via withdraw(), so it can never stall settlement.
    uint256 private constant PAYOUT_GAS_LIMIT = 100_000;

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
            settled: false
        });
        nextEscrowId = id + 1;
        emit EscrowCreated(id, msg.sender, payee, msg.value, deadline);
    }

    /// @notice Record delivery once, as the payee of an unsettled escrow.
    /// @param id Existing escrow identifier.
    /// @param workHash Nonzero commitment to the delivered work.
    function deliver(uint256 id, bytes32 workHash) external {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payee, "Only payee");
        require(!escrow.settled, "Already settled");
        require(!escrow.delivered, "Already delivered");
        require(workHash != bytes32(0), "Empty work hash");

        escrow.delivered = true;
        escrow.workHash = workHash;
        emit Delivered(id, workHash);
    }

    /// @notice Release the full delivered escrow amount to its payee, as its payer.
    /// @dev A failed payout credits the payee for withdrawal; the escrow remains settled.
    /// @param id Existing, delivered, unsettled escrow identifier.
    function release(uint256 id) external nonReentrant {
        Escrow storage escrow = escrows[id];
        require(escrow.payer != address(0), "Escrow not found");
        require(msg.sender == escrow.payer, "Only payer");
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
            _payOrCredit(recipients[i], amount);
        }
        emit SplitPaid(msg.sender, msg.value, count);
    }

    /// @dev Attempt a native-token payout, crediting the recipient if its call fails.
    function _payOrCredit(address to, uint256 amount) internal {
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
