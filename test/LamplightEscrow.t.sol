// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "../contracts/LamplightEscrow.sol";

/// @notice A recipient whose receive() refuses payment while `reverting`
///   is set, and accepts it once cleared. Lets a test prove that a failed
///   direct payout credits pendingWithdrawals, and that the same recipient
///   can later pull the credit with withdraw().
contract FlakyRecipient {
    bool public reverting = true;

    function setReverting(bool v) external {
        reverting = v;
    }

    /// @dev Contracts cannot sign transactions, so this helper lets the
    ///   test drive withdraw() as the recipient.
    function withdrawFrom(address payable escrow_) external {
        LamplightEscrow(escrow_).withdraw();
    }

    receive() external payable {
        require(!reverting, "FlakyRecipient: refusing");
    }
}

/// @notice A recipient that burns far more than the 100,000-gas direct
///   payout cap on every receive (10 fresh SSTOREs, ~22k gas each).
///   Proves the cap bounds griefing: the capped call fails, the amount is
///   credited, and the settlement itself does not revert.
contract GasBurner {
    receive() external payable {
        for (uint256 i = 0; i < 10; i++) {
            assembly {
                sstore(i, 1)
            }
        }
    }
}

/// @notice A recipient that burns a fixed, configurable amount of gas in
///   receive(). Lets a test prove the payout gas guard forwards the full
///   100,000 gas: a ~95k burn is paid directly at the new threshold, while
///   under the old 5,000 buffer the same gas limit would have forwarded
///   only ~93.5k and credited it instead. If the forwarded gas is ever
///   less than the burn amount, the spin loop runs the call out of gas and
///   the amount is credited — the correct failure mode.
contract GasBurnerExact {
    uint256 public immutable burnAmount;

    constructor(uint256 burnAmount_) {
        burnAmount = burnAmount_;
    }

    receive() external payable {
        uint256 start = gasleft();
        uint256 target = start > burnAmount ? start - burnAmount : 0;
        while (gasleft() > target) {}
    }
}

/// @notice A contract with no receive() or fallback at all: it can never
///   accept a native-token payment. Proves a credit to such a contract is
///   unrecoverable via withdraw() (which pays to the credited address
///   itself) but recoverable via withdrawTo() to a payable address.
///   Also the exact repro for the unrecoverable-credit finding: such a
///   contract funds an escrow, misses its deadline, and is credited on
///   refund because the direct payout fails.
contract NoReceive {
    /// @dev Contracts cannot sign transactions, so these helpers let the
    ///   test drive the escrow as this contract.
    function createEscrowAsPayer(address payable escrow_, address payee_, uint256 deadline)
        external
        payable
        returns (uint256)
    {
        return LamplightEscrow(escrow_).createEscrow{value: msg.value}(payee_, deadline);
    }

    function refundAsPayer(address payable escrow_, uint256 id) external {
        LamplightEscrow(escrow_).refund(id);
    }

    function withdrawAsCreditor(address payable escrow_) external {
        LamplightEscrow(escrow_).withdraw();
    }

    function withdrawToAsCreditor(address payable escrow_, address to) external {
        LamplightEscrow(escrow_).withdrawTo(to);
    }
}

/// @notice A payee/payer that tries to reenter the escrow from receive().
///   Proves the nonReentrant guard holds: the reentry reverts, the
///   settlement still completes, and any credit is preserved.
contract ReentrantAttacker {
    LamplightEscrow public immutable esc;
    uint256 public targetId;
    bool public attackWithdraw;
    bool public attackRelease;
    bool public attackRefund;

    constructor(address payable esc_) {
        esc = LamplightEscrow(esc_);
    }

    function setTarget(uint256 id) external {
        targetId = id;
    }

    function setAttackWithdraw(bool v) external {
        attackWithdraw = v;
    }

    function setAttackRelease(bool v) external {
        attackRelease = v;
    }

    function setAttackRefund(bool v) external {
        attackRefund = v;
    }

    /// @dev Turn all attacks off. Needed because a reverted receive() frame
    ///   rolls back its own flag reset, so an attack flag stays set until
    ///   the test clears it explicitly.
    function disarm() external {
        attackWithdraw = false;
        attackRelease = false;
        attackRefund = false;
    }

    /// @dev Contracts cannot sign transactions, so this helper lets the
    ///   test fund an escrow as the attacker.
    function createEscrowAsPayer(address payee_, uint256 deadline)
        external
        payable
        returns (uint256)
    {
        return esc.createEscrow{value: msg.value}(payee_, deadline);
    }

    /// @dev Lets the test drive withdraw() as the attacker.
    function withdrawAsCreditor() external {
        esc.withdraw();
    }

    receive() external payable {
        if (attackWithdraw) {
            attackWithdraw = false;
            esc.withdraw();
        } else if (attackRelease) {
            attackRelease = false;
            esc.release(targetId);
        } else if (attackRefund) {
            attackRefund = false;
            esc.refund(targetId);
        }
    }
}

/// @notice Full happy-path + failure tests for LamplightEscrow (pull design).
/// Run: forge test
contract LamplightEscrowTest is Test {
    LamplightEscrow esc;
    address payer = address(0xA11CE);
    address payee = address(0xBEEF);
    address third = address(0xCAFE);
    address arbiter = address(0xA9B17E9);
    address backupArbiter = address(0xBAC4);
    FlakyRecipient flaky;

    function setUp() public {
        esc = new LamplightEscrow();
        flaky = new FlakyRecipient();
        vm.deal(payer, 100 ether);
        vm.deal(payee, 1 ether);
        vm.deal(third, 1 ether);
        // Round 2: the arbiters must hold funds to stake bonds.
        vm.deal(arbiter, 10 ether);
        vm.deal(backupArbiter, 10 ether);
    }

    function _create(uint256 amount, uint256 deadlineIn) internal returns (uint256) {
        vm.prank(payer);
        return esc.createEscrow{value: amount}(payee, block.timestamp + deadlineIn);
    }

    function _createWithArbiter(uint256 amount, uint256 deadlineIn, address arbiter_) internal returns (uint256) {
        vm.prank(payer);
        return esc.createEscrow{value: amount}(payee, block.timestamp + deadlineIn, arbiter_);
    }

    /// @dev Round 2: create with the full five-argument overload.
    function _createFull(
        uint256 amount,
        uint256 deadlineIn,
        address arbiter_,
        address backup_,
        uint96 bond_
    ) internal returns (uint256) {
        vm.prank(payer);
        return esc.createEscrow{value: amount}(payee, block.timestamp + deadlineIn, arbiter_, backup_, bond_);
    }

    function _createWithBackup(uint256 amount, uint256 deadlineIn) internal returns (uint256) {
        return _createFull(amount, deadlineIn, arbiter, backupArbiter, 0);
    }

    function _createWithBond(uint256 amount, uint256 deadlineIn, uint96 bond_) internal returns (uint256) {
        return _createFull(amount, deadlineIn, arbiter, address(0), bond_);
    }

    function _createWithBackupAndBond(uint256 amount, uint256 deadlineIn, uint96 bond_)
        internal
        returns (uint256)
    {
        return _createFull(amount, deadlineIn, arbiter, backupArbiter, bond_);
    }

    /// @dev Reject, cure, then escalate — the setup every timeout/bond/backup test starts from.
    function _escalated(uint256 id) internal {
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
    }

    /// @dev Escalate, then the primary arbiter resolves — the setup every
    ///   challenge-window test starts from. With a backup arbiter named,
    ///   the resolution opens the challenge window instead of paying.
    function _resolvedWithBackup(uint256 id, bool toPayee) internal {
        _escalated(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, toPayee);
    }

    /// @dev Deliver, reject, then cure — the setup every arbiter test starts from.
    function _rejectAndCure(uint256 id) internal {
        vm.prank(payee);
        esc.deliver(id, keccak256("work v1"));
        vm.prank(payer);
        esc.rejectDelivery(id);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2 fixed"));
    }

    // ---- The 14 required cases, adapted to pull semantics ----

    function testCreateEscrowLocksFunds() public {
        uint256 id = _create(0.5 ether, 1 days);
        LamplightEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, 0.5 ether);
        assertEq(e.deliveredAt, 0); // not delivered: deliveredAt == 0
        assertFalse(e.settled);
        assertEq(address(esc).balance, 0.5 ether);
    }

    function testFullHappyPathRelease() public {
        uint256 id = _create(0.5 ether, 1 days);
        bytes32 h = keccak256("deliverable: bounty report v1");
        vm.prank(payee);
        esc.deliver(id, h);
        assertTrue(esc.getEscrow(id).deliveredAt != 0);

        uint256 before = payee.balance;
        vm.prank(payer);
        esc.release(id);
        // payee is an EOA: the direct payout succeeds, no credit is left
        assertEq(payee.balance, before + 0.5 ether);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(address(esc).balance, 0);
    }

    function testReleaseBeforeDeliveryReverts() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payer);
        vm.expectRevert("Not delivered");
        esc.release(id);
    }

    function testOnlyPayeeCanDeliver() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(third);
        vm.expectRevert("Only payee");
        esc.deliver(id, keccak256("x"));
    }

    function testOnlyPayerCanRelease() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(third);
        vm.expectRevert("Only payer");
        esc.release(id);
    }

    function testRefundAfterDeadlineWhenUndelivered() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 2 days);
        uint256 before = payer.balance;
        vm.prank(payer);
        esc.refund(id);
        // payer is an EOA: direct payout succeeds, no credit is left
        assertEq(payer.balance, before + 0.5 ether);
        assertEq(esc.pendingWithdrawals(payer), 0);
        assertTrue(esc.getEscrow(id).settled);
    }

    function testRefundBeforeDeadlineReverts() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payer);
        vm.expectRevert("Deadline not reached");
        esc.refund(id);
    }

    function testRefundAfterDeliveryReverts() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.warp(block.timestamp + 2 days);
        vm.prank(payer);
        vm.expectRevert("Already delivered");
        esc.refund(id);
    }

    function testCreateWithZeroValueReverts() public {
        vm.prank(payer);
        vm.expectRevert("Zero payment");
        esc.createEscrow{value: 0}(payee, block.timestamp + 1 days);
    }

    function testCreateWithPastDeadlineReverts() public {
        vm.prank(payer);
        vm.expectRevert("Invalid deadline");
        esc.createEscrow{value: 0.1 ether}(payee, block.timestamp - 1);
    }

    function testSplitPaymentExact() public {
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = payer;
        uint256[] memory s = new uint256[](3);
        s[0] = 5000;
        s[1] = 3000;
        s[2] = 2000;
        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        uint256 b2 = payer.balance;
        vm.prank(payer);
        esc.splitPayment{value: 1 ether}(r, s);
        // all three are EOAs: direct payouts succeed, nothing credited
        assertEq(payee.balance, b0 + 0.5 ether);
        assertEq(third.balance, b1 + 0.3 ether);
        // payer sent 1 ether and got 0.2 back as a recipient: net -0.8
        assertEq(payer.balance, b2 - 0.8 ether);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertEq(esc.pendingWithdrawals(third), 0);
        assertEq(esc.pendingWithdrawals(payer), 0);
        assertEq(address(esc).balance, 0);
    }

    function testSplitPaymentBadSharesReverts() public {
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 4000; // sums to 9000, not 10000
        vm.prank(payer);
        vm.expectRevert("Invalid shares total");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testSplitPaymentDustGoesToLast() public {
        // 1 wei cannot split 50/50; last recipient must receive the dust
        // so no value is ever trapped in the contract.
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 5000;
        vm.prank(payer);
        esc.splitPayment{value: 1}(r, s);
        assertEq(address(esc).balance, 0);
        assertEq(third.balance, 1 ether + 1);
    }

    function testDirectTransferReverts() public {
        vm.prank(payer);
        (bool ok, ) = address(esc).call{value: 0.1 ether}("");
        assertFalse(ok);
    }

    // ---- Pull-payment cases (new) ----

    function testReleaseCreditsRevertingPayeeThenWithdrawPays() public {
        FlakyRecipient flaky = new FlakyRecipient();
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(flaky),
            block.timestamp + 1 days
        );
        vm.prank(address(flaky));
        esc.deliver(id, keccak256("x"));

        vm.prank(payer);
        esc.release(id); // must NOT revert on the failed direct payout
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);
        assertEq(address(flaky).balance, 0);

        // recipient fixes itself, then pulls the credit
        flaky.setReverting(false);
        flaky.withdrawFrom(payable(address(esc)));
        assertEq(address(flaky).balance, 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testReleaseCreditsGasBurningPayee() public {
        GasBurner burner = new GasBurner();
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(burner),
            block.timestamp + 1 days
        );
        vm.prank(address(burner));
        esc.deliver(id, keccak256("x"));

        vm.prank(payer);
        esc.release(id); // capped call runs out of gas; must NOT revert
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(burner)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);
    }

    function testRefundCreditsRevertingPayerThenWithdrawPays() public {
        FlakyRecipient flaky = new FlakyRecipient();
        vm.deal(address(flaky), 1 ether);
        vm.prank(address(flaky));
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            payee,
            block.timestamp + 1 days
        );
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(flaky));
        esc.refund(id); // direct payout to a reverting payer must NOT revert
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);

        flaky.setReverting(false);
        flaky.withdrawFrom(payable(address(esc)));
        assertEq(address(flaky).balance, 1 ether);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testSplitCreditsRevertingRecipientButPaysTheOthers() public {
        FlakyRecipient flaky = new FlakyRecipient();
        address[] memory r = new address[](2);
        r[0] = address(flaky);
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 5000;
        uint256 b1 = third.balance;
        vm.prank(payer);
        esc.splitPayment{value: 1 ether}(r, s); // one broken recipient
        // must NOT revert the whole split: third is paid, flaky is credited
        assertEq(third.balance, b1 + 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);

        flaky.setReverting(false);
        flaky.withdrawFrom(payable(address(esc)));
        assertEq(address(flaky).balance, 0.5 ether);
        assertEq(address(esc).balance, 0);
    }

    function testWithdrawOnlyCreditedParty() public {
        // third has no credit at all
        vm.prank(third);
        vm.expectRevert("Nothing to withdraw");
        esc.withdraw();
    }

    function testWithdrawDoubleWithdrawReverts() public {
        FlakyRecipient flaky = new FlakyRecipient();
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(flaky),
            block.timestamp + 1 days
        );
        vm.prank(address(flaky));
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        flaky.setReverting(false);
        flaky.withdrawFrom(payable(address(esc)));
        assertEq(esc.pendingWithdrawals(address(flaky)), 0);
        vm.prank(address(flaky));
        vm.expectRevert("Nothing to withdraw");
        esc.withdraw();
    }

    // ---- Studio-exact behaviour locks (revert strings + check order) ----

    function testSplitPaymentShareOver10000Reverts() public {
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 10001; // over the per-share cap; the share check fires first
        s[1] = 0;
        vm.prank(payer);
        vm.expectRevert("Invalid share");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testSplitPaymentTooManyRecipientsReverts() public {
        address[] memory r = new address[](6);
        uint256[] memory s = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            r[i] = address(uint160(0x1000 + i));
            s[i] = 0;
        }
        s[0] = 10000;
        vm.prank(payer);
        vm.expectRevert("Invalid recipient count");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testSplitPaymentZeroShareAllowed() public {
        // Zero shares are allowed: the zero-share recipient gets no call
        // at all (and no credit), the other gets everything.
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 0;
        s[1] = 10000;
        uint256 b1 = third.balance;
        vm.prank(payer);
        esc.splitPayment{value: 1 ether}(r, s);
        assertEq(third.balance, b1 + 1 ether);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertEq(address(esc).balance, 0);
    }

    function testDeliverSettledByNonPayeeRevertsOnlyPayee() public {
        // Studio checks the caller BEFORE the settled flag in deliver():
        // a settled escrow + a non-payee caller reverts "Only payee".
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        vm.prank(third);
        vm.expectRevert("Only payee");
        esc.deliver(id, keccak256("y"));
    }

    function testReleaseSettledByNonPayerRevertsOnlyPayer() public {
        // Studio checks the caller BEFORE the settled flag in release():
        // a settled escrow + a non-payer caller reverts "Only payer".
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        vm.prank(third);
        vm.expectRevert("Only payer");
        esc.release(id);
    }

    // ---- Post-review fixes (Oct 27, 2026) ----

    function testDeliverAfterDeadlineReverts() public {
        // Finding 1: a payee must not be able to deliver after the deadline
        // and kill the payer's refund with a junk hash.
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 2 days); // past the deadline, undelivered
        vm.prank(payee);
        vm.expectRevert("Deadline passed");
        esc.deliver(id, keccak256("x"));
        // the refund the deadline was protecting is still available
        uint256 before = payer.balance;
        vm.prank(payer);
        esc.refund(id);
        assertEq(payer.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id).settled);
    }

    function testPayeeCannotClaimBeforeReviewWindowEnds() public {
        // Finding 2: inside the 7-day review window, only the payer releases.
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.warp(block.timestamp + 3 days); // inside the window
        vm.prank(payee);
        vm.expectRevert("Review period not ended");
        esc.release(id);
    }

    function testPayeeClaimsAfterReviewWindow() public {
        // Finding 2: past the window, the payee may release and claim the
        // funds, so a silent payer cannot lock them forever.
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.warp(block.timestamp + 8 days); // past the 7-day window
        uint256 before = payee.balance;
        vm.prank(payee);
        esc.release(id);
        assertEq(payee.balance, before + 0.5 ether);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(address(esc).balance, 0);
    }

    function testPayerReleasesInsideReviewWindow() public {
        // Finding 2: the payer's release inside the window is unchanged.
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.warp(block.timestamp + 3 days); // inside the window
        uint256 before = payee.balance;
        vm.prank(payer);
        esc.release(id);
        assertEq(payee.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id).settled);
    }

    function testPayerReleasesAfterReviewWindow() public {
        // Finding 2: the payer may still release after the window ends.
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.warp(block.timestamp + 8 days); // window over
        uint256 before = payee.balance;
        vm.prank(payer);
        esc.release(id);
        assertEq(payee.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id).settled);
    }

    function testReentrantReleaseIsCreditedNotDrained() public {
        // Finding 5: a payee that tries to reenter release() from receive()
        // is stopped by the guard; the settlement still completes as a credit.
        ReentrantAttacker attacker = new ReentrantAttacker(payable(address(esc)));
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(attacker),
            block.timestamp + 1 days
        );
        vm.prank(address(attacker));
        esc.deliver(id, keccak256("x"));
        attacker.setAttackRelease(true);
        attacker.setTarget(id);

        vm.prank(payer);
        esc.release(id); // must NOT revert on the failed reentrant call
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(attacker)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);
        assertEq(address(attacker).balance, 0);

        attacker.disarm();
        attacker.withdrawAsCreditor();
        assertEq(address(attacker).balance, 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testReentrantRefundIsCreditedNotDrained() public {
        // Finding 5: a payer that tries to reenter refund() from receive()
        // is stopped by the guard; the settlement still completes as a credit.
        ReentrantAttacker attacker = new ReentrantAttacker(payable(address(esc)));
        vm.deal(address(attacker), 1 ether);
        uint256 id = attacker.createEscrowAsPayer{value: 0.5 ether}(
            payee,
            block.timestamp + 1 days
        );
        vm.warp(block.timestamp + 2 days);
        attacker.setAttackRefund(true);
        attacker.setTarget(id);

        vm.prank(address(attacker));
        esc.refund(id); // must NOT revert on the failed reentrant call
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(attacker)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);

        attacker.disarm();
        attacker.withdrawAsCreditor();
        // attacker started with 1 ether dealt; the 0.5 ether escrow was
        // funded through it from the test, so it ends with 1.5 ether.
        assertEq(address(attacker).balance, 1.5 ether);
        assertEq(esc.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testReentrantWithdrawRevertsAndKeepsCredit() public {
        // Finding 5: a credited recipient that tries to reenter withdraw()
        // from receive() fails the whole withdraw ("Payment failed") and
        // the credit is preserved for a later, clean attempt.
        ReentrantAttacker attacker = new ReentrantAttacker(payable(address(esc)));
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(attacker),
            block.timestamp + 1 days
        );
        vm.prank(address(attacker));
        esc.deliver(id, keccak256("x"));
        attacker.setAttackRelease(true);
        attacker.setTarget(id);
        vm.prank(payer);
        esc.release(id); // reentry fails, amount is credited
        assertEq(esc.pendingWithdrawals(address(attacker)), 0.5 ether);

        attacker.setAttackWithdraw(true);
        vm.expectRevert("Payment failed");
        attacker.withdrawAsCreditor();
        assertEq(esc.pendingWithdrawals(address(attacker)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);

        // a clean withdraw now succeeds (all attack flags cleared)
        attacker.disarm();
        attacker.withdrawAsCreditor();
        assertEq(address(attacker).balance, 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testWithdrawToStillRevertingRecipientRevertsPaymentFailed() public {
        // Finding 5: withdraw() to a recipient that still reverts fails
        // with "Payment failed" and the credit is preserved.
        FlakyRecipient flaky = new FlakyRecipient();
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(flaky),
            block.timestamp + 1 days
        );
        vm.prank(address(flaky));
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);

        vm.expectRevert("Payment failed");
        flaky.withdrawFrom(payable(address(esc)));
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);
    }

    function testDeliverTwiceRevertsAlreadyDelivered() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payee);
        vm.expectRevert("Already delivered");
        esc.deliver(id, keccak256("y"));
    }

    function testDeliverEmptyWorkHashReverts() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        vm.expectRevert("Empty work hash");
        esc.deliver(id, bytes32(0));
    }

    function testEscrowNotFoundReverts() public {
        // id 999 was never created: every entry point rejects it first.
        vm.prank(payee);
        vm.expectRevert("Escrow not found");
        esc.deliver(999, keccak256("x"));
        vm.prank(payer);
        vm.expectRevert("Escrow not found");
        esc.release(999);
        vm.prank(payer);
        vm.expectRevert("Escrow not found");
        esc.refund(999);
    }

    function testReleaseTwiceRevertsAlreadySettled() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.release(id);
    }

    function testRefundTwiceRevertsAlreadySettled() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(payer);
        esc.refund(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.refund(id);
    }

    function testCreateEscrowInvalidPayee() public {
        vm.prank(payer);
        vm.expectRevert("Invalid payee");
        esc.createEscrow{value: 0.1 ether}(address(0), block.timestamp + 1 days);
        vm.prank(payer);
        vm.expectRevert("Invalid payee");
        esc.createEscrow{value: 0.1 ether}(payer, block.timestamp + 1 days);
    }

    function testSplitPaymentZeroRecipientReverts() public {
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = address(0);
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 5000;
        vm.prank(payer);
        vm.expectRevert("Zero recipient");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testSplitPaymentLengthMismatchReverts() public {
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = third;
        uint256[] memory s = new uint256[](3);
        s[0] = 5000;
        s[1] = 3000;
        s[2] = 2000;
        vm.prank(payer);
        vm.expectRevert("Length mismatch");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testSplitPaymentZeroRecipientsReverts() public {
        address[] memory r = new address[](0);
        uint256[] memory s = new uint256[](0);
        vm.prank(payer);
        vm.expectRevert("Invalid recipient count");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    function testFuzzSplitPaymentSumsToValue(uint256 value, uint256 s0, uint256 s1) public {
        // Finding 5 (re-review round 3): the LAST NONZERO-share recipient
        // takes the dust — not necessarily the last recipient. For any
        // value and any shares summing to 10000, every recipient except
        // the last nonzero-share one gets exactly floor(value * share /
        // 10000), the last nonzero-share one gets the remainder, a
        // zero-share recipient gets nothing, the split sums to value, and
        // nothing is left in the contract.
        value = bound(value, 1, 10 ether);
        s0 = bound(s0, 0, 10000);
        s1 = bound(s1, 0, 10000 - s0);
        uint256 s2 = 10000 - s0 - s1;

        (uint256 got0, uint256 got1, uint256 got2) =
            _splitAndMeasure(value, s0, s1, s2);
        (uint256 expect0, uint256 expect1, uint256 expect2) =
            _splitExpectations(value, s0, s1, s2);

        assertEq(got0, expect0);
        assertEq(got1, expect1);
        assertEq(got2, expect2);
        assertEq(got0 + got1 + got2, value);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertEq(esc.pendingWithdrawals(third), 0);
        assertEq(esc.pendingWithdrawals(payer), 0);
        assertEq(address(esc).balance, 0);
    }

    /// @dev Run a 3-way split as the payer and return what each recipient
    ///   netted (the payer's figure nets out the value it sent).
    function _splitAndMeasure(uint256 value, uint256 s0, uint256 s1, uint256 s2)
        internal
        returns (uint256, uint256, uint256)
    {
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = payer;
        uint256[] memory s = new uint256[](3);
        s[0] = s0;
        s[1] = s1;
        s[2] = s2;
        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        uint256 b2 = payer.balance;
        vm.prank(payer);
        esc.splitPayment{value: value}(r, s);
        return (payee.balance - b0, third.balance - b1, (payer.balance + value) - b2);
    }

    /// @dev Expected split amounts under the dust rule: the last NONZERO-share
    ///   recipient takes the remainder; every other recipient gets exactly
    ///   floor(value * share / 10000); a zero-share recipient gets nothing.
    function _splitExpectations(uint256 value, uint256 s0, uint256 s1, uint256 s2)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        uint256 lastNz = s2 > 0 ? 2 : (s1 > 0 ? 1 : 0);
        uint256 expect0 = lastNz == 0 ? value : (value * s0) / 10000;
        uint256 expect1 = lastNz == 1 ? value - expect0 : (value * s1) / 10000;
        uint256 expect2 = lastNz == 2 ? value - expect0 - expect1 : 0;
        return (expect0, expect1, expect2);
    }

    // ---- Re-review fix (Oct 27, 2026): gas-guard buffer ----

    function testPayoutGasGuardRevertsWhenCallerUnderfundsGas() public {
        // Re-review Low: the old 5,000 buffer did not cover the CALL base
        // cost, so a caller could tune the gas limit to just above the old
        // threshold (~106,587) and silently under-forward to the payee.
        // The 40,000 buffer raises the threshold to ~141,587; a caller
        // leaving ~120,000 gas at the check (above the old threshold, below
        // the new one) must now fail loudly instead. The release path burns
        // ~33,000 gas before the check after struct packing (was ~75,000),
        // so a 153,000 gas limit lands at ~120,000 gas left.
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        vm.expectRevert("Insufficient gas for payout");
        esc.release{gas: 153_000}(id);
    }

    function testPayoutGasGuardForwardsFullCapAtBoundary() public {
        // Re-review Low: at the new threshold (~141,587 gas left at the
        // check), the full 100,000 gas must actually reach the recipient.
        // A recipient burning ~99,000 gas is paid directly — under the old
        // 5,000 buffer the same gas limit would have forwarded only ~93.5k
        // and credited it instead. A 220,000 gas limit lands at ~145,000
        // gas left at the check, just above the threshold.
        GasBurnerExact burner = new GasBurnerExact(99_000);
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(burner),
            block.timestamp + 1 days
        );
        vm.prank(address(burner));
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release{gas: 220_000}(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(address(burner).balance, 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(burner)), 0);
        assertEq(address(esc).balance, 0);
    }

    // ---- Re-review round 3 (Oct 27, 2026): dust + unrecoverable credit ----

    function testSplitPaymentZeroShareLastGetsNoDust() public {
        // Claude Low (round 3): the exact repro. splitPayment{value: 1}
        // with shares [5000, 5000, 0] must NOT pay or call the zero-share
        // last recipient: the 1 wei of dust goes to the last NONZERO-share
        // recipient (third), and the zero-share last gets nothing — not
        // even a call, so a reverting one gets no spurious Credited event.
        FlakyRecipient flaky = new FlakyRecipient(); // reverting, as C
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = address(flaky);
        uint256[] memory s = new uint256[](3);
        s[0] = 5000;
        s[1] = 5000;
        s[2] = 0;
        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        vm.prank(payer);
        esc.splitPayment{value: 1}(r, s);
        assertEq(payee.balance, b0); // 0 share, 0 wei — and no call
        assertEq(third.balance, b1 + 1); // dust to the last nonzero share
        assertEq(esc.pendingWithdrawals(address(flaky)), 0); // no call, no credit
        assertEq(address(esc).balance, 0);
    }

    function testSplitPaymentDustGoesToLastNonZeroShare() public {
        // The dust still lands with a nonzero-share last recipient:
        // value 3, shares [5000, 3000, 2000] -> floors 1 and 0, last
        // takes 3 - 1 - 0 = 2 (its 0 floor + 2 dust).
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = payer;
        uint256[] memory s = new uint256[](3);
        s[0] = 5000;
        s[1] = 3000;
        s[2] = 2000;
        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        uint256 b2 = payer.balance;
        vm.prank(payer);
        esc.splitPayment{value: 3}(r, s);
        assertEq(payee.balance, b0 + 1);
        assertEq(third.balance, b1);
        // payer sent 3 and got 2 back as the last recipient: net -1
        assertEq(payer.balance, b2 - 1);
        assertEq(address(esc).balance, 0);
    }

    function testWithdrawToRecoversCreditForNonPayableContract() public {
        // Claude Low (round 3): the exact repro. A contract with no
        // payable receive() funds an escrow and misses its deadline; the
        // refund's direct payout fails, so it is credited — and
        // withdraw() to itself then reverts with "Payment failed"
        // forever. withdrawTo() to a payable address recovers it.
        NoReceive nr = new NoReceive();
        vm.deal(address(nr), 1 ether);
        uint256 id = nr.createEscrowAsPayer{value: 0.5 ether}(
            payable(address(esc)),
            payee,
            block.timestamp + 1 days
        );
        vm.warp(block.timestamp + 2 days);
        nr.refundAsPayer(payable(address(esc)), id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(esc.pendingWithdrawals(address(nr)), 0.5 ether);
        assertEq(address(esc).balance, 0.5 ether);

        vm.expectRevert("Payment failed");
        nr.withdrawAsCreditor(payable(address(esc)));
        assertEq(esc.pendingWithdrawals(address(nr)), 0.5 ether);

        uint256 b = third.balance;
        nr.withdrawToAsCreditor(payable(address(esc)), third);
        assertEq(third.balance, b + 0.5 ether);
        assertEq(esc.pendingWithdrawals(address(nr)), 0);
        assertEq(address(esc).balance, 0);
    }

    function testWithdrawToZeroAddressReverts() public {
        // withdrawTo() to the zero address is rejected, not silently lost.
        FlakyRecipient flaky = new FlakyRecipient();
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(flaky),
            block.timestamp + 1 days
        );
        vm.prank(address(flaky));
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        vm.prank(address(flaky));
        vm.expectRevert("Zero recipient");
        esc.withdrawTo(address(0));
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
    }

    function testCreateEscrowRejectsEscrowContractAsPayee() public {
        // A payee of address(this) would strand the payout: release()
        // pays the escrow, its receive() reverts, the amount is credited
        // to the escrow itself, and the escrow can never withdraw.
        vm.prank(payer);
        vm.expectRevert("Invalid payee");
        esc.createEscrow{value: 0.1 ether}(address(esc), block.timestamp + 1 days);
    }

    function testSplitPaymentRejectsEscrowContractAsRecipient() public {
        // Same stranding in a split: address(this) as a recipient would
        // be credited on the failed call and could never pull it.
        address[] memory r = new address[](2);
        r[0] = payee;
        r[1] = address(esc);
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 5000;
        vm.prank(payer);
        vm.expectRevert("Invalid recipient");
        esc.splitPayment{value: 1 ether}(r, s);
    }

    // ---- Round 4 (Oct 27, 2026): struct packing ----

    function testPackedStructFieldsRoundTrip() public {
        // The packed struct (uint96 amount, uint40 deadline/deliveredAt/
        // rejectedAt, deliveredAt != 0 as the delivered flag, plus the
        // rejectedOnce and deadlineExtended bools) must read back exactly
        // what createEscrow stored.
        uint256 id = _create(0.5 ether, 1 days);
        LamplightEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, 0.5 ether);
        assertEq(e.deadline, block.timestamp + 1 days);
        assertEq(e.deliveredAt, 0);
        assertEq(e.rejectedAt, 0);
        assertEq(e.workHash, bytes32(0));
        assertFalse(e.settled);
        assertFalse(e.rejectedOnce);
        assertFalse(e.deadlineExtended);
        // after delivery the packed fields update in place
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        e = esc.getEscrow(id);
        assertEq(e.deliveredAt, block.timestamp);
        assertEq(e.workHash, keccak256("x"));
        assertFalse(e.settled);
    }

    function testCreateEscrowAmountTooLargeReverts() public {
        // Amounts above 2**96 wei cannot fit the packed uint96 slot and
        // must revert rather than truncate.
        vm.deal(payer, type(uint256).max);
        vm.prank(payer);
        vm.expectRevert("Amount too large");
        esc.createEscrow{value: uint256(type(uint96).max) + 1}(
            payee,
            block.timestamp + 1 days
        );
    }

    function testCreateEscrowDeadlineTooLargeReverts() public {
        // A deadline past 2**40 seconds cannot fit the packed uint40 slot.
        vm.prank(payer);
        vm.expectRevert("Invalid deadline");
        esc.createEscrow{value: 0.1 ether}(payee, uint256(type(uint40).max) + 1);
    }

    function testPackedStructRejectAndExtendFlagsRoundTrip() public {
        // The two new bools round-trip: a rejection sets rejectedOnce (and
        // it stays set after the cure clears rejectedAt), and an extension
        // sets deadlineExtended with the new deadline.
        uint256 id = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id);
        assertTrue(esc.getEscrow(id).rejectedOnce);
        vm.prank(payee);
        esc.deliver(id, keccak256("cured"));
        assertTrue(esc.getEscrow(id).rejectedOnce); // stays set after cure
        assertEq(esc.getEscrow(id).rejectedAt, 0);

        uint256 id2 = _create(0.5 ether, 1 days);
        uint256 oldDeadline = esc.getEscrow(id2).deadline;
        vm.prank(payer);
        esc.extendDeadline(id2, 2 days);
        LamplightEscrow.Escrow memory e2 = esc.getEscrow(id2);
        assertTrue(e2.deadlineExtended);
        assertEq(e2.deadline, oldDeadline + 2 days);
    }

    // ---- Round 4: discriminating gas-guard tests (Claude improvement 1) ----

    /// @dev Binary-search the smallest low-level gas limit at which
    ///   release() to `payee_` succeeds. Each probe uses a fresh escrow
    ///   (a successful probe settles it). The search adapts to the
    ///   release path's actual pre-check gas burn, so the tests below do
    ///   not hard-code it.
    function _minGasForDirectPay(address payee_) internal returns (uint256) {
        uint256 lo = 150_000; // known to revert at the guard
        uint256 hi = 300_000; // known to succeed
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(payer);
            uint256 id = esc.createEscrow{value: 0.5 ether}(
                payee_,
                block.timestamp + 1 days
            );
            vm.prank(payee_);
            esc.deliver(id, keccak256("x"));
            vm.prank(payer);
            (bool ok, ) = address(esc).call{gas: mid}(
                abi.encodeWithSignature("release(uint256)", id)
            );
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function testGasGuardSweepNeverCredits() public {
        // Claude improvement 1: the property is "if the guard passes, the
        // payee is never credited". Sweep the gas limit across the
        // threshold with a ~99.9k burner: below the threshold the call
        // must revert, above it the burner is paid directly — at NO limit
        // may the burner be credited, and the outcomes must be monotonic
        // (all reverts, then all successes).
        uint256 firstSuccess = type(uint256).max;
        uint256 lastRevert = 0;
        for (uint256 limit = 150_000; limit <= 280_000; limit += 5_000) {
            GasBurnerExact burner = new GasBurnerExact(99_900);
            vm.prank(payer);
            uint256 id = esc.createEscrow{value: 0.5 ether}(
                address(burner),
                block.timestamp + 1 days
            );
            vm.prank(address(burner));
            esc.deliver(id, keccak256("x"));
            vm.prank(payer);
            (bool ok, ) = address(esc).call{gas: limit}(
                abi.encodeWithSignature("release(uint256)", id)
            );
            // the property: a failed guard reverts, a passed guard pays —
            // a credit must never appear at any gas limit.
            assertEq(esc.pendingWithdrawals(address(burner)), 0);
            if (ok) {
                assertEq(address(burner).balance, 0.5 ether);
                if (firstSuccess == type(uint256).max) firstSuccess = limit;
            } else {
                assertFalse(esc.getEscrow(id).settled);
                lastRevert = limit;
            }
        }
        assertTrue(firstSuccess != type(uint256).max, "no limit paid directly");
        assertTrue(lastRevert != 0, "no limit reverted");
        assertTrue(lastRevert < firstSuccess, "outcomes not monotonic");
    }

    function testGasGuardGapRevertsInsteadOfCrediting() public {
        // The discriminating case the old boundary test missed: 15,000 gas
        // below the new threshold, gasleft at the check lands in the gap
        // between the old 5,000-buffer threshold (~106,587) and the new
        // 40,000-buffer threshold (~141,587). Under the old buffer the
        // guard would have passed here and the ~99.9k burner would have
        // been credited silently (only ~90k forwarded after the CALL base
        // cost). Under the new buffer it must fail loudly instead — and
        // the escrow must stay unsettled with nothing credited.
        GasBurnerExact burner = new GasBurnerExact(99_900);
        uint256 minLimit = _minGasForDirectPay(address(burner));
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            address(burner),
            block.timestamp + 1 days
        );
        vm.prank(address(burner));
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        vm.expectRevert("Insufficient gas for payout");
        esc.release{gas: minLimit - 15_000}(id);
        assertEq(esc.pendingWithdrawals(address(burner)), 0);
        assertFalse(esc.getEscrow(id).settled);
    }

    function testGasGuardCoversColdEmptyAccount() public {
        // Grok improvement 3 (Arc): the worst-case CALL base cost is a
        // cold, empty account — 2,600 cold + 9,000 value + 25,000 empty =
        // 36,600, which the 40,000 buffer covers. A fresh address with no
        // code and no balance, paid at the threshold limit, must be paid
        // directly, never credited.
        address coldEmpty = address(0xF00D);
        assertEq(coldEmpty.balance, 0);
        assertEq(coldEmpty.code.length, 0);
        uint256 minLimit = _minGasForDirectPay(coldEmpty);
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(
            coldEmpty,
            block.timestamp + 1 days
        );
        vm.prank(coldEmpty);
        esc.deliver(id, keccak256("x"));
        uint256 before = coldEmpty.balance; // the binary search already
        // paid this address on its successful probes; assert the delta
        vm.prank(payer);
        esc.release{gas: minLimit}(id);
        assertEq(coldEmpty.balance, before + 0.5 ether);
        assertEq(esc.pendingWithdrawals(coldEmpty), 0);
        assertTrue(esc.getEscrow(id).settled);
    }

    // ---- Round 4: credit event distinguishability (Grok improvement 1) ----

    bytes32 constant RELEASED_SIG = keccak256("Released(uint256,address,uint256)");
    bytes32 constant CREDITED_SIG = keccak256("Credited(address,uint256)");
    bytes32 constant SPLIT_PAID_SIG = keccak256("SplitPaid(address,uint256,uint256)");

    function _hasEvent(Vm.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    function _countEvent(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) ++n;
        }
    }

    function testCreditedEventDistinguishesCreditFromDirectPay() public {
        // Grok improvement 1, verified: the Credited event is emitted ONLY
        // on the failed-push path, and every settlement emits its own
        // event — so an indexer distinguishes a pull credit from a direct
        // payment by the presence of Credited in the same transaction.
        // (1) Direct payment: Released, no Credited.
        vm.recordLogs();
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("x"));
        vm.prank(payer);
        esc.release(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_hasEvent(logs, RELEASED_SIG));
        assertFalse(_hasEvent(logs, CREDITED_SIG));
        // (2) Failed push: Released AND Credited, credit matches the amount.
        FlakyRecipient flaky = new FlakyRecipient();
        vm.recordLogs();
        vm.prank(payer);
        uint256 id2 = esc.createEscrow{value: 0.5 ether}(
            address(flaky),
            block.timestamp + 1 days
        );
        vm.prank(address(flaky));
        esc.deliver(id2, keccak256("x"));
        vm.prank(payer);
        esc.release(id2);
        logs = vm.getRecordedLogs();
        assertTrue(_hasEvent(logs, RELEASED_SIG));
        assertTrue(_hasEvent(logs, CREDITED_SIG));
        assertEq(_countEvent(logs, CREDITED_SIG), 1);
        assertEq(esc.pendingWithdrawals(address(flaky)), 0.5 ether);
        // (3) Split: SplitPaid + exactly one Credited, for the broken
        // recipient only — the good recipient gets no Credited event.
        // A fresh flaky recipient: the first one already holds a 0.5
        // ether credit from part (2), and credits accumulate.
        FlakyRecipient flaky2 = new FlakyRecipient();
        vm.recordLogs();
        address[] memory r = new address[](2);
        r[0] = address(flaky2);
        r[1] = third;
        uint256[] memory s = new uint256[](2);
        s[0] = 5000;
        s[1] = 5000;
        vm.prank(payer);
        esc.splitPayment{value: 1 ether}(r, s);
        logs = vm.getRecordedLogs();
        assertTrue(_hasEvent(logs, SPLIT_PAID_SIG));
        assertEq(_countEvent(logs, CREDITED_SIG), 1);
        assertEq(esc.pendingWithdrawals(address(flaky2)), 0.5 ether);
        assertEq(esc.pendingWithdrawals(third), 0);
    }

    // ---- Round 4: payer reject + dispute path (Claude feature) ----

    function _delivered(uint256 amount) internal returns (uint256) {
        uint256 id = _create(amount, 30 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v1"));
        return id;
    }

    function testRejectInsideWindowThenCure() public {
        // The payer rejects a junk delivery inside the review window; the
        // payee cures with a corrected hash; the cured delivery releases
        // normally — the happy path is unchanged after a cure.
        uint256 id = _delivered(0.5 ether);
        vm.warp(block.timestamp + 1 days); // inside the 7-day window
        vm.prank(payer);
        esc.rejectDelivery(id);
        LamplightEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.deliveredAt, 0);
        assertEq(e.rejectedAt, block.timestamp);
        assertEq(e.workHash, bytes32(0));
        assertFalse(e.settled);
        // release is impossible while rejected (nothing delivered)
        vm.prank(payer);
        vm.expectRevert("Not delivered");
        esc.release(id);
        // the payee cures with a corrected hash
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2 fixed"));
        e = esc.getEscrow(id);
        assertEq(e.rejectedAt, 0); // cure clears the rejection
        assertEq(e.workHash, keccak256("work v2 fixed"));
        // and the cured delivery releases normally
        uint256 before = payee.balance;
        vm.prank(payer);
        esc.release(id);
        assertEq(payee.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id).settled);
    }

    function testRejectEmitsRejectedWorkHash() public {
        // Grok improvement 1 (round 7): the rejected work hash is emitted
        // in DeliveryRejected, so off-chain parties can prove what was
        // rejected after the clear. After a cure + re-delivery, the live
        // hash is the new one — the rejected hash survives only in the
        // event history (the struct holds zero right after the reject,
        // then the corrected hash after the cure).
        uint256 id = _delivered(0.5 ether); // delivers keccak256("work v1")
        bytes32 rejectedHash = keccak256("work v1");
        vm.expectEmit(true, true, false, true);
        emit LamplightEscrow.DeliveryRejected(id, payer, rejectedHash);
        vm.prank(payer);
        esc.rejectDelivery(id);
        assertEq(esc.getEscrow(id).workHash, bytes32(0));
        // the payee cures with a corrected hash; the live hash is the new one
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2 fixed"));
        assertEq(esc.getEscrow(id).workHash, keccak256("work v2 fixed"));
        assertEq(esc.getEscrow(id).rejectedAt, 0);
    }

    function testRejectEventFieldsAndStorageZeroed() public {
        // Grok improvement 1 (round 8): the round-7 test pins the emitted
        // hash via expectEmit; this companion reads the raw log, so the
        // indexed fields are asserted explicitly — topic[1] is the
        // escrow id, topic[2] is the payer — and the workHash is zeroed
        // in storage immediately after the emit, before any cure. The
        // rejected hash then survives only in the event history.
        uint256 id = _delivered(0.5 ether); // delivers keccak256("work v1")
        bytes32 rejectedHash = keccak256("work v1");
        vm.recordLogs();
        vm.prank(payer);
        esc.rejectDelivery(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); // reject emits exactly one event
        assertEq(logs[0].topics[0], keccak256("DeliveryRejected(uint256,address,bytes32)"));
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(payer))));
        assertEq(abi.decode(logs[0].data, (bytes32)), rejectedHash);
        assertEq(esc.getEscrow(id).workHash, bytes32(0));
        assertTrue(esc.getEscrow(id).rejectedAt != 0); // cure clock started
    }

    function testRejectAfterWindowReverts() public {
        // A reject after the review window ends is too late: at the exact
        // boundary second the payee may already claim, so the payee wins
        // the boundary and the reject reverts.
        uint256 id = _delivered(0.5 ether);
        vm.warp(block.timestamp + 7 days); // exactly deliveredAt + REVIEW_PERIOD
        vm.prank(payer);
        vm.expectRevert("Review period ended");
        esc.rejectDelivery(id);
        // the payee claims instead, as the boundary rule provides
        uint256 before = payee.balance;
        vm.prank(payee);
        esc.release(id);
        assertEq(payee.balance, before + 0.5 ether);
    }

    function testRejectUncuredThenPayerRefunds() public {
        // The payee does not cure within the 7-day cure window; the payer
        // refunds. Before the cure window ends the refund reverts.
        uint256 id = _delivered(0.5 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(payer);
        esc.rejectDelivery(id);
        uint256 rejectedAt = esc.getEscrow(id).rejectedAt;
        vm.warp(block.timestamp + 2 days); // inside the cure window
        vm.prank(payer);
        vm.expectRevert("Cure period not ended");
        esc.refundAfterRejection(id);
        vm.warp(rejectedAt + 7 days); // cure window over
        uint256 before = payer.balance;
        vm.prank(payer);
        esc.refundAfterRejection(id);
        assertEq(payer.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(address(esc).balance, 0);
    }

    function testRejectUndeliveredReverts() public {
        // Rejecting an escrow with no delivery is meaningless and reverts.
        uint256 id = _create(0.5 ether, 30 days);
        vm.prank(payer);
        vm.expectRevert("Not delivered");
        esc.rejectDelivery(id);
    }

    function testRejectTwiceReverts() public {
        // A second rejection of the same delivery reverts; the cure clock
        // is not restarted by re-rejecting.
        uint256 id = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id);
        vm.prank(payer);
        vm.expectRevert("Already rejected");
        esc.rejectDelivery(id);
    }

    function testRejectOnlyPayer() public {
        uint256 id = _delivered(0.5 ether);
        vm.prank(third);
        vm.expectRevert("Only payer");
        esc.rejectDelivery(id);
        vm.prank(payee);
        vm.expectRevert("Only payer");
        esc.rejectDelivery(id);
    }

    function testRefundAfterRejectionOnlyAfterRejection() public {
        // refundAfterRejection on a never-rejected escrow reverts, even
        // after the deadline — the deadline path is refund(), not this one.
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(payer);
        vm.expectRevert("Not rejected");
        esc.refundAfterRejection(id);
    }

    function testSecondRejectionAfterCureReverts() public {
        // Round 5 (Claude High, one-rejection cap): a cured delivery
        // CANNOT be rejected again. The first rejection starts the cure;
        // the cure clears rejectedAt but rejectedOnce stays set, so the
        // second rejectDelivery reverts "Already rejected" — a payer
        // cannot reject every cured delivery in turn.
        uint256 id = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2 still junk"));
        vm.prank(payer);
        vm.expectRevert("Already rejected");
        esc.rejectDelivery(id);
        // and the cured delivery still releases normally
        vm.prank(payer);
        esc.release(id);
        assertTrue(esc.getEscrow(id).settled);
    }

    // ---- Round 5 (Oct 27, 2026): reject/cure fixes (Claude High + Medium) ----

    function testRejectedEscrowCannotTakePlainRefund() public {
        // Claude High (round 5): the exact repro. Payee delivers at D-1;
        // at D+1 (inside the 7-day review window) the payer rejects; the
        // rejection clears deliveredAt, so the OLD refund() would have
        // passed (deliveredAt == 0, now >= deadline) and taken back
        // paid-for work with no cure possible. Now refund() reverts
        // "Already rejected" and the only exit is refundAfterRejection
        // after the cure window ends.
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 1 days - 1); // D-1
        vm.prank(payee);
        esc.deliver(id, keccak256("good work"));
        vm.warp(block.timestamp + 2); // D+1, inside the review window
        vm.prank(payer);
        esc.rejectDelivery(id);
        // plain refund() must NOT work on a rejected escrow
        vm.prank(payer);
        vm.expectRevert("Already rejected");
        esc.refund(id);
        // and the cure is still open: the payee can re-deliver past the
        // deadline, inside the cure window (FIX A part 2)
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2"));
        assertEq(esc.getEscrow(id).deliveredAt, block.timestamp);
        // a second escrow proves the refundAfterRejection exit still works
        uint256 id2 = _create(0.5 ether, 1 days);
        vm.prank(payee);
        esc.deliver(id2, keccak256("work"));
        vm.warp(block.timestamp + 1 days); // past the deadline, inside window
        vm.prank(payer);
        esc.rejectDelivery(id2);
        vm.prank(payer);
        vm.expectRevert("Already rejected");
        esc.refund(id2);
        vm.warp(block.timestamp + 7 days); // cure window over
        uint256 before = payer.balance;
        vm.prank(payer);
        esc.refundAfterRejection(id2);
        assertEq(payer.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id2).settled);
    }

    function testCureAfterCurePeriodReverts() public {
        // Claude Medium (round 5): the cure window is enforced on the
        // payee side. After rejectedAt + 7 days the payee can no longer
        // re-deliver — even if the deadline has not passed — so a junk
        // hash cannot front-run the payer's refundAfterRejection and buy
        // a fresh 7-day review window.
        uint256 id = _delivered(0.5 ether); // 30-day deadline
        vm.prank(payer);
        esc.rejectDelivery(id);
        uint256 rejectedAt = esc.getEscrow(id).rejectedAt;
        vm.warp(rejectedAt + 7 days - 1); // last second of the cure window
        vm.prank(payee);
        esc.deliver(id, keccak256("just in time"));
        // and the boundary on a second escrow: at the cure end it reverts
        uint256 id2 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id2);
        uint256 rejectedAt2 = esc.getEscrow(id2).rejectedAt;
        vm.warp(rejectedAt2 + 7 days); // exactly the cure end
        vm.prank(payee);
        vm.expectRevert("Cure period ended");
        esc.deliver(id2, keccak256("too late"));
        // and the payer's refundAfterRejection is now open
        vm.prank(payer);
        esc.refundAfterRejection(id2);
        assertTrue(esc.getEscrow(id2).settled);
    }

    // ---- Round 5: reviewWindows view helper (Grok improvement 1) ----

    function testReviewWindowsMatchesBehaviorAtBoundaries() public {
        // Grok improvement (round 5): reviewWindows() mirrors HSK's
        // claimWindows. Before delivery both are 0; after delivery the
        // review end matches the release/reject boundary; after a
        // rejection the cure end matches the cure/refund boundary.
        uint256 id0 = _create(0.5 ether, 30 days);
        (uint256 r0, uint256 c0) = esc.reviewWindows(id0);
        assertEq(r0, 0);
        assertEq(c0, 0);

        uint256 id = _delivered(0.5 ether);
        uint256 deliveredAt = esc.getEscrow(id).deliveredAt;
        (uint256 reviewEnd, uint256 cureEnd) = esc.reviewWindows(id);
        assertEq(reviewEnd, deliveredAt + 7 days);
        assertEq(cureEnd, 0); // not rejected
        // at the exact review end the payee may claim and the payer may
        // not reject — the helper's value is the real boundary
        vm.warp(reviewEnd);
        vm.prank(payer);
        vm.expectRevert("Review period ended");
        esc.rejectDelivery(id);
        vm.prank(payee);
        esc.release(id);
        assertTrue(esc.getEscrow(id).settled);

        // cure end: reject, then the helper's cure end is the real boundary
        uint256 id2 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id2);
        (reviewEnd, cureEnd) = esc.reviewWindows(id2);
        assertEq(reviewEnd, 0); // cleared by the rejection
        uint256 rejectedAt = esc.getEscrow(id2).rejectedAt;
        assertEq(cureEnd, rejectedAt + 7 days);
        vm.warp(cureEnd - 1); // last second of the cure window
        vm.prank(payee);
        esc.deliver(id2, keccak256("cured in time"));
        assertEq(esc.getEscrow(id2).rejectedAt, 0);
    }

    // ---- Round 5: extend deadline (Grok feature) ----

    function testExtendDeadlineWorks() public {
        uint256 id = _create(0.5 ether, 1 days);
        uint256 oldDeadline = esc.getEscrow(id).deadline;
        vm.prank(payer);
        esc.extendDeadline(id, 2 days);
        assertEq(esc.getEscrow(id).deadline, oldDeadline + 2 days);
        // the payee can now deliver in the extended window
        vm.warp(oldDeadline + 1 days); // past the ORIGINAL deadline
        vm.prank(payee);
        esc.deliver(id, keccak256("in the extension"));
        assertEq(esc.getEscrow(id).deliveredAt, block.timestamp);
    }

    function testExtendDeadlineAfterDeliveryReverts() public {
        uint256 id = _delivered(0.5 ether);
        vm.prank(payer);
        vm.expectRevert("Already delivered");
        esc.extendDeadline(id, 1 days);
    }

    function testExtendDeadlineBeyondBoundReverts() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payer);
        vm.expectRevert("Invalid extension");
        esc.extendDeadline(id, 7 days + 1);
        vm.prank(payer);
        vm.expectRevert("Invalid extension");
        esc.extendDeadline(id, 0);
        // exactly 7 days works
        vm.prank(payer);
        esc.extendDeadline(id, 7 days);
        assertEq(esc.getEscrow(id).deadline, block.timestamp + 1 days + 7 days);
    }

    function testExtendDeadlineOnlyOnce() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payer);
        esc.extendDeadline(id, 1 days);
        vm.prank(payer);
        vm.expectRevert("Deadline already extended");
        esc.extendDeadline(id, 1 days);
    }

    function testExtendDeadlineOnlyPayerAndNotWhileRejected() public {
        uint256 id = _create(0.5 ether, 1 days);
        vm.prank(payee);
        vm.expectRevert("Only payer");
        esc.extendDeadline(id, 1 days);
        uint256 id2 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id2);
        vm.prank(payer);
        vm.expectRevert("Already rejected");
        esc.extendDeadline(id2, 1 days);
    }

    // ---- Round 5: splitPayment fuzz, full uint96 range (Grok improvement 3) ----

    function testSplitPaymentFuzzFullUint96(uint256 value, uint256 s0, uint256 s1) public {
        // Grok improvement (round 5): sweep msg.value across the full
        // uint96 range with random share vectors summing to 10,000.
        // The contract balance must end at zero and the dust must always
        // land on a non-zero-share recipient.
        // Round 6 (Claude improvement): bound() instead of vm.assume —
        // assume() on a uint256 can reject most inputs and risks "too
        // many rejects" flakiness.
        value = bound(value, 1, type(uint96).max);
        s0 = bound(s0, 0, 10000);
        s1 = bound(s1, 0, 10000 - s0);
        uint256 s2 = 10000 - s0 - s1;
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = payer;
        uint256[] memory s = new uint256[](3);
        s[0] = s0;
        s[1] = s1;
        s[2] = s2;
        vm.deal(payer, value);
        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        uint256 b2 = payer.balance;
        vm.prank(payer);
        esc.splitPayment{value: value}(r, s);
        assertEq(address(esc).balance, 0);
        (uint256 e0, uint256 e1, uint256 e2) = _splitExpectations(value, s0, s1, s2);
        assertEq(payee.balance, b0 + e0);
        assertEq(third.balance, b1 + e1);
        // payer sent `value` and received e2 back as the last recipient
        assertEq(payer.balance, b2 + e2 - value);
    }

    // ---- Round 5: balance invariant + boundary tests (Claude improvement) ----

    /// @dev The balance invariant: the contract holds exactly the sum of
    ///   unsettled escrow amounts plus all outstanding pull credits.
    ///   Every account that can hold a credit in this test is listed.
    ///   Round 6 (Grok improvement): also assert no single pull credit
    ///   exceeds the contract's native balance — a credit is a claim on
    ///   funds the contract actually holds.
    function _assertBalanceInvariant(uint256[] memory ids, uint256 count) internal view {
        uint256 expected;
        for (uint256 i = 0; i < count; ++i) {
            LamplightEscrow.Escrow memory e = esc.getEscrow(ids[i]);
            if (!e.settled) expected += e.amount;
        }
        expected += esc.pendingWithdrawals(payer);
        expected += esc.pendingWithdrawals(payee);
        expected += esc.pendingWithdrawals(third);
        expected += esc.pendingWithdrawals(address(flaky));
        assertEq(address(esc).balance, expected);
        assertLe(esc.pendingWithdrawals(payer), address(esc).balance);
        assertLe(esc.pendingWithdrawals(payee), address(esc).balance);
        assertLe(esc.pendingWithdrawals(third), address(esc).balance);
        assertLe(esc.pendingWithdrawals(address(flaky)), address(esc).balance);
    }

    function testFuzzBalanceInvariant(uint256 seed) public {
        // Claude improvement (round 5): fuzz over amounts and settlement
        // paths; assert the balance invariant after every step. All
        // escrows carry a 30-day deadline so the cure-window warps never
        // pass a deadline; choice-3 (never deliver) escrows are refunded
        // in a second pass, after one warp past all deadlines.
        uint256 n = seed % 3 + 1; // 1..3 escrows
        uint256[] memory ids = new uint256[](n);
        uint256[] memory choices = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 amount = (uint256(keccak256(abi.encode(seed, "amt", i))) % 0.01 ether) + 1;
            vm.prank(payer);
            ids[i] = esc.createEscrow{value: amount}(payee, block.timestamp + 30 days);
            choices[i] = uint256(keccak256(abi.encode(seed, "act", i))) % 4;
            _assertBalanceInvariant(ids, i + 1);
        }
        for (uint256 i = 0; i < n; ++i) {
            if (choices[i] == 3) continue; // refunded in the second pass
            vm.prank(payee);
            esc.deliver(ids[i], keccak256(abi.encode(seed, i)));
            _assertBalanceInvariant(ids, n);
            if (choices[i] == 0) {
                // deliver then release
                vm.prank(payer);
                esc.release(ids[i]);
            } else if (choices[i] == 1) {
                // deliver, reject, cure, release
                vm.prank(payer);
                esc.rejectDelivery(ids[i]);
                _assertBalanceInvariant(ids, n);
                vm.prank(payee);
                esc.deliver(ids[i], keccak256(abi.encode(seed, i, "cure")));
                vm.prank(payer);
                esc.release(ids[i]);
            } else {
                // deliver, reject, no cure, refund after the cure window
                vm.prank(payer);
                esc.rejectDelivery(ids[i]);
                uint256 rejectedAt = esc.getEscrow(ids[i]).rejectedAt;
                vm.warp(rejectedAt + 7 days);
                vm.prank(payer);
                esc.refundAfterRejection(ids[i]);
            }
            _assertBalanceInvariant(ids, n);
        }
        for (uint256 i = 0; i < n; ++i) {
            if (choices[i] != 3) continue;
            uint256 deadline = esc.getEscrow(ids[i]).deadline;
            vm.warp(deadline + 1);
            vm.prank(payer);
            esc.refund(ids[i]);
            _assertBalanceInvariant(ids, n);
        }
        // a split across the EOA payee, third, and the reverting flaky
        // recipient — the flaky share credits, the good shares pay out
        uint256 splitValue = (uint256(keccak256(abi.encode(seed, "split"))) % 0.01 ether) + 1;
        uint256 s0 = uint256(keccak256(abi.encode(seed, "s0"))) % 10000;
        uint256 s1 = uint256(keccak256(abi.encode(seed, "s1"))) % (10000 - s0);
        uint256 s2 = 10000 - s0 - s1;
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = address(flaky);
        uint256[] memory s = new uint256[](3);
        s[0] = s0;
        s[1] = s1;
        s[2] = s2;
        vm.prank(payer);
        esc.splitPayment{value: splitValue}(r, s);
        _assertBalanceInvariant(ids, n);
        // pull the flaky credit out and the invariant still holds
        flaky.setReverting(false);
        flaky.withdrawFrom(payable(address(esc)));
        _assertBalanceInvariant(ids, n);
    }

    function testDeadlineAndCureBoundaryEdges() public {
        // Claude improvement (round 5): pin the edges. Deliver at
        // deadline-1 succeeds; at the deadline it reverts. Cure at
        // cure-end-1 succeeds; at the cure end it reverts. Refund after
        // rejection at cure-end-1 reverts; at the cure end it succeeds.
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 1 days - 1); // deadline - 1
        vm.prank(payee);
        esc.deliver(id, keccak256("just in time"));
        assertEq(esc.getEscrow(id).deliveredAt, block.timestamp);

        uint256 id2 = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 1 days); // exactly the deadline
        vm.prank(payee);
        vm.expectRevert("Deadline passed");
        esc.deliver(id2, keccak256("too late"));

        uint256 id3 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id3);
        uint256 rejectedAt = esc.getEscrow(id3).rejectedAt;
        vm.warp(rejectedAt + 7 days - 1); // last second of the cure window
        vm.prank(payee);
        esc.deliver(id3, keccak256("cured in time"));

        uint256 id4 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id4);
        uint256 rejectedAt4 = esc.getEscrow(id4).rejectedAt;
        vm.warp(rejectedAt4 + 7 days - 1);
        vm.prank(payer);
        vm.expectRevert("Cure period not ended");
        esc.refundAfterRejection(id4);
        vm.warp(rejectedAt4 + 7 days); // exactly the cure end
        vm.prank(payer);
        esc.refundAfterRejection(id4);
        assertTrue(esc.getEscrow(id4).settled);
    }

    // ---- Round 6 (Oct 27, 2026): cure window equals review window ----

    function testRejectAtReviewEndMinusOneSecondCureLastsFullSevenDays() public {
        // Claude Medium (round 6): the cure window was 3 days while the
        // review window is 7, so a payer could reject at deliveredAt +
        // 7d - 1s and win by default if the payee was offline 3 days.
        // REJECT_CURE_PERIOD is now REVIEW_PERIOD (7 days): the payee
        // still has the full cure window even after a last-second reject.
        uint256 id = _delivered(0.5 ether);
        uint256 deliveredAt = esc.getEscrow(id).deliveredAt;
        vm.warp(deliveredAt + 7 days - 1); // last second of the review window
        vm.prank(payer);
        esc.rejectDelivery(id);
        uint256 rejectedAt = esc.getEscrow(id).rejectedAt;
        // 6 days later the cure is still open — under the old 3-day cure
        // the payee would already have lost
        vm.warp(rejectedAt + 6 days);
        vm.prank(payee);
        esc.deliver(id, keccak256("cured on day six"));
        assertEq(esc.getEscrow(id).rejectedAt, 0);
        // and the cured delivery releases normally
        vm.prank(payer);
        esc.release(id);
        assertTrue(esc.getEscrow(id).settled);

        // a second escrow pins the refund side: no refund before the cure
        // ends, refund open at the cure end
        uint256 id2 = _delivered(0.5 ether);
        uint256 deliveredAt2 = esc.getEscrow(id2).deliveredAt;
        vm.warp(deliveredAt2 + 7 days - 1);
        vm.prank(payer);
        esc.rejectDelivery(id2);
        uint256 rejectedAt2 = esc.getEscrow(id2).rejectedAt;
        vm.warp(rejectedAt2 + 7 days - 1); // last second of the cure window
        vm.prank(payer);
        vm.expectRevert("Cure period not ended");
        esc.refundAfterRejection(id2);
        vm.warp(rejectedAt2 + 7 days); // exactly the cure end
        uint256 before = payer.balance;
        vm.prank(payer);
        esc.refundAfterRejection(id2);
        assertEq(payer.balance, before + 0.5 ether);
        assertTrue(esc.getEscrow(id2).settled);
    }

    // ---- Round 6 (Oct 27, 2026): extendDeadline after the deadline ----

    function testExtendDeadlineAfterDeadlineReverts() public {
        // Claude Low (round 6): extendDeadline had no
        // block.timestamp < deadline check, so a payer could revive an
        // expired undelivered escrow and let the payee deliver again.
        // An expired escrow stays expired.
        uint256 id = _create(0.5 ether, 1 days);
        vm.warp(block.timestamp + 1 days); // exactly the deadline
        vm.prank(payer);
        vm.expectRevert("Deadline passed");
        esc.extendDeadline(id, 1 days);
        // and the refund path is still the only exit
        vm.prank(payer);
        esc.refund(id);
        assertTrue(esc.getEscrow(id).settled);
    }

    // ---- Round 6 (Oct 27, 2026): lifecycleStatus view (Grok improvement) ----

    function testLifecycleStatusCoversAllStates() public {
        // Grok improvement (round 6): one view returns the full lifecycle
        // state, so front-ends never re-derive it from the three
        // timestamps. Walk escrows through every state.
        assertEq(
            uint256(esc.lifecycleStatus(999)),
            uint256(LamplightEscrow.Lifecycle.Nonexistent)
        );

        uint256 id = _create(0.5 ether, 1 days);
        assertEq(
            uint256(esc.lifecycleStatus(id)),
            uint256(LamplightEscrow.Lifecycle.Created)
        );
        vm.warp(block.timestamp + 1 days); // exactly the deadline
        assertEq(
            uint256(esc.lifecycleStatus(id)),
            uint256(LamplightEscrow.Lifecycle.Expired)
        );

        uint256 id2 = _delivered(0.5 ether);
        assertEq(
            uint256(esc.lifecycleStatus(id2)),
            uint256(LamplightEscrow.Lifecycle.InReview)
        );
        uint256 deliveredAt2 = esc.getEscrow(id2).deliveredAt;
        vm.warp(deliveredAt2 + 7 days); // review window over
        assertEq(
            uint256(esc.lifecycleStatus(id2)),
            uint256(LamplightEscrow.Lifecycle.Claimable)
        );

        uint256 id3 = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id3);
        assertEq(
            uint256(esc.lifecycleStatus(id3)),
            uint256(LamplightEscrow.Lifecycle.CureOpen)
        );
        uint256 rejectedAt3 = esc.getEscrow(id3).rejectedAt;
        vm.warp(rejectedAt3 + 7 days); // cure window over
        assertEq(
            uint256(esc.lifecycleStatus(id3)),
            uint256(LamplightEscrow.Lifecycle.Rejected)
        );

        vm.prank(payer);
        esc.refundAfterRejection(id3);
        assertEq(
            uint256(esc.lifecycleStatus(id3)),
            uint256(LamplightEscrow.Lifecycle.Settled)
        );
        vm.prank(payer);
        esc.release(id2);
        assertEq(
            uint256(esc.lifecycleStatus(id2)),
            uint256(LamplightEscrow.Lifecycle.Settled)
        );
    }

    // ---- V2 (Oct 27, 2026): optional per-escrow arbiter ----

    function testArbiterEscalateAndReleaseToPayee() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.expectEmit(true, true, true, true);
        emit LamplightEscrow.DisputeEscalated(id, payer, arbiter);
        vm.prank(payer);
        esc.escalateDispute(id);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.Escalated));
        vm.expectEmit(true, true, false, true);
        emit LamplightEscrow.DisputeResolved(id, arbiter, true);
        vm.prank(arbiter);
        esc.resolveDispute(id, true);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether); // 1 ether from setUp + 0.5 released
        assertEq(address(esc).balance, 0);
    }

    function testArbiterEscalateAndRefundToPayer() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, false);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1 ether); // payee got nothing
        assertEq(address(esc).balance, 0);
    }

    function testEscalateWithoutArbiterReverts() public {
        uint256 id = _create(0.5 ether, 1 days); // no arbiter: address(0)
        assertEq(esc.getEscrow(id).arbiter, address(0));
        _rejectAndCure(id);
        vm.prank(payer);
        vm.expectRevert("No arbiter");
        esc.escalateDispute(id);
    }

    function testEscalateByNonPayerReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payee);
        vm.expectRevert("Only payer");
        esc.escalateDispute(id);
        vm.prank(arbiter);
        vm.expectRevert("Only payer");
        esc.escalateDispute(id);
    }

    function testEscalateBeforeRejectionReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v1")); // delivered, never rejected
        vm.prank(payer);
        vm.expectRevert("Not rejected");
        esc.escalateDispute(id);
    }

    function testEscalateBeforeCureReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v1"));
        vm.prank(payer);
        esc.rejectDelivery(id); // rejected, not yet cured
        vm.prank(payer);
        vm.expectRevert("Not delivered");
        esc.escalateDispute(id);
    }

    function testEscalateAfterReviewWindowReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        uint256 deliveredAt = esc.getEscrow(id).deliveredAt;
        vm.warp(deliveredAt + 7 days); // review window over
        vm.prank(payer);
        vm.expectRevert("Review period ended");
        esc.escalateDispute(id);
    }

    function testEscalateTwiceReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        vm.prank(payer);
        vm.expectRevert("Already escalated");
        esc.escalateDispute(id);
    }

    function testArbiterCannotResolveTwice() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, true);
        vm.prank(arbiter);
        vm.expectRevert("Already settled");
        esc.resolveDispute(id, true);
    }

    function testSecondEscalationAfterResolutionReverts() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, false);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.escalateDispute(id);
    }

    function testReleaseBlockedWhileEscalated() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _rejectAndCure(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        vm.prank(payer);
        vm.expectRevert("Disputed");
        esc.release(id);
        // after the review window the payee could normally claim — not while escalated
        uint256 deliveredAt = esc.getEscrow(id).deliveredAt;
        vm.warp(deliveredAt + 7 days);
        vm.prank(payee);
        vm.expectRevert("Disputed");
        esc.release(id);
        assertFalse(esc.getEscrow(id).settled);
    }

    function testArbiterCannotBePayerOrPayee() public {
        vm.prank(payer);
        vm.expectRevert("Invalid arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, block.timestamp + 1 days, payer);
        vm.prank(payer);
        vm.expectRevert("Invalid arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, block.timestamp + 1 days, payee);
        vm.prank(payer);
        vm.expectRevert("Invalid arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, block.timestamp + 1 days, address(esc));
    }

    function testPayeeCanReadArbiterBeforeDelivering() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        assertEq(esc.getEscrow(id).arbiter, arbiter);
        uint256 plain = _create(0.5 ether, 1 days);
        assertEq(esc.getEscrow(plain).arbiter, address(0));
    }

    function testLifecycleEscalated() public {
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.Created));
        _rejectAndCure(id);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.InReview));
        vm.prank(payer);
        esc.escalateDispute(id);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.Escalated));
        vm.prank(arbiter);
        esc.resolveDispute(id, true);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.Settled));
    }

    // ---- V2 round 2 (Oct 27, 2026): arbiter timeout ----

    function testArbiterTimeoutBefore14DaysReverts() public {
        // The timeout is 14 days from escalation: at 14 days minus one
        // second neither party may force-refund yet.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _escalated(id);
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 14 days - 1);
        vm.prank(payer);
        vm.expectRevert("Arbiter timeout not reached");
        esc.resolveDisputeTimeout(id);
        vm.prank(payee);
        vm.expectRevert("Arbiter timeout not reached");
        esc.resolveDisputeTimeout(id);
        assertFalse(esc.getEscrow(id).settled);
    }

    function testArbiterTimeoutRefundsPayerAtBoundary() public {
        // At exactly escalatedAt + 14 days the payer may force-refund.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _escalated(id);
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 14 days);
        uint256 before = payer.balance;
        vm.expectEmit(true, true, false, false);
        emit LamplightEscrow.DisputeTimedOut(id, payer);
        vm.prank(payer);
        esc.resolveDisputeTimeout(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, before + 0.5 ether);
        assertEq(address(esc).balance, 0);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.Settled));
    }

    function testArbiterTimeoutPayeeCanCall() public {
        // Either party may time out a silent arbiter — the payee too,
        // since a refund unblocks the payee's next job as well.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _escalated(id);
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 15 days); // past the boundary
        uint256 before = payer.balance;
        vm.prank(payee);
        esc.resolveDisputeTimeout(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, before + 0.5 ether);
        assertEq(address(esc).balance, 0);
    }

    function testArbiterTimeoutBlocksFurtherActions() public {
        // After a timeout the escrow is settled: the arbiter can no
        // longer resolve it, and no party can release, refund, or
        // re-escalate.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _escalated(id);
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 14 days);
        vm.prank(payer);
        esc.resolveDisputeTimeout(id);
        vm.prank(arbiter);
        vm.expectRevert("Already settled");
        esc.resolveDispute(id, true);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.release(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.refund(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.escalateDispute(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.resolveDisputeTimeout(id);
    }

    function testArbiterTimeoutForfeitsBond() public {
        // A staked bond is forfeited to the payer when the arbiter it
        // was staked against times out: the payer gets the escrow
        // amount AND the bond; the silent arbiter loses its stake.
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        assertEq(arbiter.balance, 9.9 ether);
        _escalated(id);
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 14 days);
        vm.prank(payer);
        esc.resolveDisputeTimeout(id);
        assertTrue(esc.getEscrow(id).settled);
        // payer: 100 - 0.5 funded + 0.5 refunded + 0.1 forfeited bond
        assertEq(payer.balance, 100.1 ether);
        assertEq(arbiter.balance, 9.9 ether); // bond lost
        assertEq(address(esc).balance, 0);
    }

    function testBackupArbiterTimeoutReturnsBond() public {
        // The bond is the PRIMARY arbiter's stake, and it acted — so a
        // timeout of the BACKUP arbiter forfeits nothing: the bond
        // returns to the primary arbiter and the payer is refunded.
        uint256 id = _createWithBackupAndBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        _resolvedWithBackup(id, true); // primary resolves to the payee
        vm.prank(payer);
        esc.reEscalate(id); // challenge: backup arbiter's turn
        uint256 escalatedAt = esc.getEscrow(id).escalatedAt;
        vm.warp(escalatedAt + 14 days);
        vm.prank(payee);
        esc.resolveDisputeTimeout(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, 100 ether); // refunded in full
        assertEq(arbiter.balance, 10 ether); // bond returned, not forfeited
        assertEq(address(esc).balance, 0);
    }

    // ---- V2 round 2: EscrowCreated carries the arbiter terms ----

    function testEscrowCreatedEmitsArbiterFields() public {
        // The five-argument creation emits arbiter, backup arbiter, and
        // bond amount, so indexers and UIs need no second call.
        uint256 deadline = block.timestamp + 1 days;
        vm.expectEmit(true, true, true, true);
        emit LamplightEscrow.EscrowCreated(0, payer, payee, 0.5 ether, deadline, arbiter, backupArbiter, 0.1 ether);
        vm.prank(payer);
        uint256 id = esc.createEscrow{value: 0.5 ether}(payee, deadline, arbiter, backupArbiter, 0.1 ether);
        assertEq(id, 0);
        // and the two-argument version emits zeros for all three terms
        vm.expectEmit(true, true, true, true);
        emit LamplightEscrow.EscrowCreated(1, payer, payee, 0.5 ether, deadline, address(0), address(0), 0);
        vm.prank(payer);
        uint256 plain = esc.createEscrow{value: 0.5 ether}(payee, deadline);
        assertEq(plain, 1);
    }

    // ---- V2 round 2: arbiter bond ----

    function testBondStakedRefundedOnArbiterRelease() public {
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        assertTrue(esc.getEscrow(id).bondStaked);
        _escalated(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, true);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether);
        assertEq(arbiter.balance, 10 ether); // bond returned in full
        assertEq(address(esc).balance, 0);
    }

    function testBondStakedRefundedOnArbiterRefund() public {
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        _escalated(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, false);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, 100 ether); // refunded in full
        assertEq(arbiter.balance, 10 ether); // bond returned in full
        assertEq(address(esc).balance, 0);
    }

    function testEscalateWithoutBondReverts() public {
        // A bond set at creation gates escalation: the payer cannot
        // escalate to an arbiter who has not staked. Once staked,
        // escalation works.
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        _rejectAndCure(id);
        vm.prank(payer);
        vm.expectRevert("Bond not staked");
        esc.escalateDispute(id);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        vm.prank(payer);
        esc.escalateDispute(id);
        assertTrue(esc.getEscrow(id).escalated);
    }

    function testStakeBondWrongAmountReverts() public {
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        vm.expectRevert("Wrong bond amount");
        esc.stakeBond{value: 0.05 ether}(id);
        vm.prank(arbiter);
        vm.expectRevert("Wrong bond amount");
        esc.stakeBond{value: 0.2 ether}(id);
        assertFalse(esc.getEscrow(id).bondStaked);
    }

    function testStakeBondOnlyArbiter() public {
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(payer);
        vm.expectRevert("Only arbiter");
        esc.stakeBond{value: 0.1 ether}(id);
        vm.prank(payee);
        vm.expectRevert("Only arbiter");
        esc.stakeBond{value: 0.1 ether}(id);
        vm.prank(third);
        vm.expectRevert("Only arbiter");
        esc.stakeBond{value: 0.1 ether}(id);
    }

    function testStakeBondTwiceReverts() public {
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        vm.prank(arbiter);
        vm.expectRevert("Bond already staked");
        esc.stakeBond{value: 0.1 ether}(id);
    }

    function testStakeBondNoBondSetReverts() public {
        // No bond amount at creation means there is nothing to stake.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        vm.prank(arbiter);
        vm.expectRevert("No bond set");
        esc.stakeBond{value: 0}(id);
    }

    function testBondReturnedOnNormalRelease() public {
        // A staked bond returns to the arbiter when the escrow settles
        // WITHOUT any escalation — a normal release must not strand it.
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        vm.prank(payee);
        esc.deliver(id, keccak256("work"));
        vm.prank(payer);
        esc.release(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether);
        assertEq(arbiter.balance, 10 ether); // bond returned
        assertEq(address(esc).balance, 0);
    }

    function testBondReturnedOnNormalRefund() public {
        // Same on the refund path: an undelivered escrow refunds the
        // payer and returns the staked bond to the arbiter.
        uint256 id = _createWithBond(0.5 ether, 1 days, 0.1 ether);
        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(payer);
        esc.refund(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, 100 ether);
        assertEq(arbiter.balance, 10 ether); // bond returned
        assertEq(address(esc).balance, 0);
    }

    function testCreateBondWithoutArbiterReverts() public {
        // A bond with no arbiter is meaningless and reverts at creation.
        vm.prank(payer);
        vm.expectRevert("No arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, block.timestamp + 1 days, address(0), address(0), 0.1 ether);
    }

    // ---- V2 round 2: backup arbiter + challenge window ----

    function testBackupReEscalationByPayerReverses() public {
        // Primary resolves to the payee; the payer challenges; the
        // backup arbiter reverses to the payer. The second resolution
        // pays out immediately and is final.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        assertFalse(esc.getEscrow(id).settled);
        assertTrue(esc.getEscrow(id).challengeOpen);
        assertEq(uint256(esc.lifecycleStatus(id)), uint256(LamplightEscrow.Lifecycle.ChallengeOpen));
        vm.expectEmit(true, true, true, true);
        emit LamplightEscrow.DisputeChallenged(id, payer, backupArbiter);
        vm.prank(payer);
        esc.reEscalate(id);
        assertTrue(esc.getEscrow(id).challenged);
        assertTrue(esc.getEscrow(id).escalated);
        assertFalse(esc.getEscrow(id).challengeOpen);
        vm.prank(backupArbiter);
        esc.resolveDispute(id, false);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, 100 ether); // refunded in full
        assertEq(payee.balance, 1 ether); // payee got nothing
        assertEq(address(esc).balance, 0);
    }

    function testBackupReEscalationByPayeeReverses() public {
        // Primary resolves to the payer; the payee challenges; the
        // backup arbiter reverses to the payee.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, false);
        assertTrue(esc.getEscrow(id).challengeOpen);
        vm.prank(payee);
        esc.reEscalate(id);
        vm.prank(backupArbiter);
        esc.resolveDispute(id, true);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether);
        assertEq(payer.balance, 99.5 ether);
        assertEq(address(esc).balance, 0);
    }

    function testReEscalateAfterWindowReverts() public {
        // At exactly resolvedAt + 2 days the challenge window is over:
        // re-escalation reverts, and finalization pays the recorded
        // decision instead.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        uint256 resolvedAt = esc.getEscrow(id).resolvedAt;
        vm.warp(resolvedAt + 2 days);
        vm.prank(payer);
        vm.expectRevert("Challenge period ended");
        esc.reEscalate(id);
        vm.prank(payee);
        vm.expectRevert("Challenge period ended");
        esc.reEscalate(id);
        // finalization is now open and pays the recorded decision
        vm.prank(third);
        esc.finalizeResolution(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether);
        assertEq(address(esc).balance, 0);
    }

    function testReEscalateWithoutBackupReverts() public {
        // No backup arbiter named means no challenge exists: the
        // primary resolution pays immediately, and re-escalation is
        // impossible.
        uint256 id = _createWithArbiter(0.5 ether, 1 days, arbiter);
        _escalated(id);
        vm.prank(arbiter);
        esc.resolveDispute(id, true);
        assertTrue(esc.getEscrow(id).settled); // paid immediately
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.reEscalate(id);
    }

    function testReEscalateOnUnresolvedEscrowReverts() public {
        // Re-escalation before any resolution is meaningless.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _escalated(id);
        vm.prank(payer);
        vm.expectRevert("Not resolved");
        esc.reEscalate(id);
    }

    function testSecondResolutionIsFinal() public {
        // After the backup arbiter resolves, nothing re-opens the
        // dispute: no second challenge, no escalation, no finalization,
        // no further resolution by either arbiter.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        vm.prank(payer);
        esc.reEscalate(id);
        vm.prank(backupArbiter);
        esc.resolveDispute(id, false);
        assertTrue(esc.getEscrow(id).settled);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.reEscalate(id);
        vm.prank(payer);
        vm.expectRevert("Already settled");
        esc.escalateDispute(id);
        vm.prank(third);
        vm.expectRevert("Already settled");
        esc.finalizeResolution(id);
        // the primary arbiter is no longer the resolver once challenged:
        // its re-call fails the caller check, not the settled check
        vm.prank(arbiter);
        vm.expectRevert("Only backup arbiter");
        esc.resolveDispute(id, true);
        vm.prank(backupArbiter);
        vm.expectRevert("Already settled");
        esc.resolveDispute(id, true);
    }

    function testFinalizeAfterWindowPaysRecordedDecision() public {
        // Nobody challenges; after the window anyone may finalize, and
        // the recorded decision pays out — here, to the payee.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        uint256 resolvedAt = esc.getEscrow(id).resolvedAt;
        vm.warp(resolvedAt + 2 days + 1);
        vm.prank(third); // anyone may finalize
        esc.finalizeResolution(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payee.balance, 1.5 ether);
        assertEq(address(esc).balance, 0);
    }

    function testFinalizeAfterWindowPaysRefundDecision() public {
        // Same, with the recorded decision a refund to the payer.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, false);
        uint256 resolvedAt = esc.getEscrow(id).resolvedAt;
        vm.warp(resolvedAt + 3 days);
        vm.prank(payer);
        esc.finalizeResolution(id);
        assertTrue(esc.getEscrow(id).settled);
        assertEq(payer.balance, 100 ether);
        assertEq(address(esc).balance, 0);
    }

    function testFinalizeDuringWindowReverts() public {
        // Finalization before the window closes reverts — the challenge
        // must still be possible.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        uint256 resolvedAt = esc.getEscrow(id).resolvedAt;
        vm.warp(resolvedAt + 2 days - 1); // last second of the window
        vm.prank(payer);
        vm.expectRevert("Challenge period not ended");
        esc.finalizeResolution(id);
        assertFalse(esc.getEscrow(id).settled);
    }

    function testReleaseBlockedDuringChallengeWindow() public {
        // While the challenge window is open the payout is deferred:
        // neither the payer (inside the review window) nor the payee
        // (after it) can release around the arbiter's decision.
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        vm.prank(payer);
        vm.expectRevert("Resolution pending");
        esc.release(id);
        uint256 deliveredAt = esc.getEscrow(id).deliveredAt;
        vm.warp(deliveredAt + 7 days); // review window over
        vm.prank(payee);
        vm.expectRevert("Resolution pending");
        esc.release(id);
        assertFalse(esc.getEscrow(id).settled);
    }

    function testPrimaryCannotResolveAgainDuringChallenge() public {
        // During the challenge window the primary arbiter cannot resolve
        // again (the escrow is not escalated), and the payer cannot
        // escalate it again either (a resolution is pending).
        uint256 id = _createWithBackup(0.5 ether, 1 days);
        _resolvedWithBackup(id, true);
        vm.prank(arbiter);
        vm.expectRevert("Not escalated");
        esc.resolveDispute(id, false);
        vm.prank(payer);
        vm.expectRevert("Resolution pending");
        esc.escalateDispute(id);
    }

    function testBackupArbiterValidation() public {
        uint256 deadline = block.timestamp + 1 days;
        // backup must differ from the arbiter
        vm.prank(payer);
        vm.expectRevert("Invalid backup arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, deadline, arbiter, arbiter, 0);
        // backup must not be the payer
        vm.prank(payer);
        vm.expectRevert("Invalid backup arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, deadline, arbiter, payer, 0);
        // backup must not be the payee
        vm.prank(payer);
        vm.expectRevert("Invalid backup arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, deadline, arbiter, payee, 0);
        // backup must not be the contract
        vm.prank(payer);
        vm.expectRevert("Invalid backup arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, deadline, arbiter, address(esc), 0);
        // backup without any arbiter is meaningless
        vm.prank(payer);
        vm.expectRevert("Invalid backup arbiter");
        esc.createEscrow{value: 0.5 ether}(payee, deadline, address(0), backupArbiter, 0);
    }

    // ---- V2 round 2: struct round-trip for the new fields ----

    function testV2Round2StructFieldsRoundTrip() public {
        uint256 id = _createWithBackupAndBond(0.5 ether, 30 days, 0.1 ether);
        LamplightEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.arbiter, arbiter);
        assertEq(e.backupArbiter, backupArbiter);
        assertEq(e.bondAmount, 0.1 ether);
        assertEq(e.escalatedAt, 0);
        assertEq(e.resolvedAt, 0);
        assertFalse(e.resolvedToPayee);
        assertFalse(e.bondStaked);
        assertFalse(e.challenged);
        assertFalse(e.challengeOpen);

        vm.prank(arbiter);
        esc.stakeBond{value: 0.1 ether}(id);
        assertTrue(esc.getEscrow(id).bondStaked);

        _escalated(id);
        e = esc.getEscrow(id);
        assertTrue(e.escalatedAt != 0);

        vm.prank(arbiter);
        esc.resolveDispute(id, true); // backup named: opens the challenge
        e = esc.getEscrow(id);
        assertTrue(e.challengeOpen);
        assertTrue(e.resolvedAt != 0);
        assertTrue(e.resolvedToPayee);
        assertFalse(e.settled); // payout deferred until finalize/challenge

        uint256 resolvedAt = e.resolvedAt;
        vm.warp(resolvedAt + 2 days);
        vm.prank(third);
        esc.finalizeResolution(id);
        e = esc.getEscrow(id);
        assertTrue(e.settled);
        assertFalse(e.challengeOpen);
        assertEq(e.resolvedAt, 0);
        assertEq(payee.balance, 1.5 ether);
        assertEq(arbiter.balance, 10 ether); // bond returned at finalize
    }
}

/// @notice Handler for the balance invariant (round 6, Claude
///   improvement): drives the escrow through random sequences of
///   creates, deliveries, rejects, releases, refunds, extensions and
///   splits. The handler itself is the payer of the escrows it creates;
///   it acts as the payee via prank. Every call is wrapped in try/catch
///   — a revert is a legal outcome (wrong actor, wrong window), the
///   invariant is about state consistency, not about calls succeeding.
contract EscrowInvariantHandler is Test {
    LamplightEscrow public esc;
    address public payee = address(0xBEEF);
    address public third = address(0xCAFE);
    uint256[] public ids;

    constructor(LamplightEscrow esc_) {
        esc = esc_;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (ids.length == 0) return type(uint256).max; // sentinel: no escrow yet
        return ids[seed % ids.length];
    }

    function create(uint256 amount, uint256 deadlineIn) external {
        amount = bound(amount, 1, 0.01 ether);
        deadlineIn = bound(deadlineIn, 1 days, 30 days);
        try esc.createEscrow{value: amount}(payee, block.timestamp + deadlineIn) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function deliver(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        vm.prank(payee);
        try esc.deliver(id, keccak256(abi.encode(seed))) {} catch {}
    }

    function reject(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.rejectDelivery(id) {} catch {}
    }

    function release(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.release(id) {} catch {}
    }

    function refund(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.refund(id) {} catch {}
    }

    function refundAfterRejection(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.refundAfterRejection(id) {} catch {}
    }

    function extend(uint256 seed, uint256 extra) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        extra = bound(extra, 1, 7 days);
        try esc.extendDeadline(id, extra) {} catch {}
    }

    function split(uint256 value, uint256 s0, uint256 s1) external {
        value = bound(value, 1, 0.01 ether);
        s0 = bound(s0, 0, 10000);
        s1 = bound(s1, 0, 10000 - s0);
        uint256 s2 = 10000 - s0 - s1;
        address[] memory r = new address[](3);
        r[0] = payee;
        r[1] = third;
        r[2] = address(this);
        uint256[] memory s = new uint256[](3);
        s[0] = s0;
        s[1] = s1;
        s[2] = s2;
        try esc.splitPayment{value: value}(r, s) {} catch {}
    }

    function withdraw() external {
        try esc.withdraw() {} catch {}
    }

    receive() external payable {}
}

/// @notice Invariant test with a handler (round 6, Claude improvement):
///   random sequences of escrow actions must never break the balance
///   invariant — the contract holds exactly the unsettled escrow amounts
///   plus all outstanding pull credits — and no single credit may exceed
///   the contract's balance. The seeded path fuzz
///   (testFuzzBalanceInvariant) covers the same property along scripted
///   paths; this one covers it along arbitrary handler-driven sequences.
contract LamplightEscrowInvariantTest is Test {
    LamplightEscrow esc;
    EscrowInvariantHandler handler;

    function setUp() public {
        esc = new LamplightEscrow();
        handler = new EscrowInvariantHandler(esc);
        vm.deal(address(handler), 100 ether);
        targetContract(address(handler));
    }

    function invariant_BalanceHolds() public view {
        uint256 expected;
        for (uint256 i = 0; i < handler.idsLength(); ++i) {
            LamplightEscrow.Escrow memory e = esc.getEscrow(handler.ids(i));
            if (!e.settled) expected += e.amount;
        }
        expected += esc.pendingWithdrawals(address(handler));
        expected += esc.pendingWithdrawals(handler.payee());
        expected += esc.pendingWithdrawals(handler.third());
        assertEq(address(esc).balance, expected);
        assertLe(esc.pendingWithdrawals(address(handler)), address(esc).balance);
        assertLe(esc.pendingWithdrawals(handler.payee()), address(esc).balance);
        assertLe(esc.pendingWithdrawals(handler.third()), address(esc).balance);
    }
}

/// @notice Handler for the dispute invariant (round 2, Oct 27, 2026):
///   drives arbiter escrows through random sequences of creates,
///   deliveries, rejects, cures, bond stakes, escalations, resolutions,
///   timeouts, re-escalations, finalizations, releases and refunds.
///   The handler itself is the payer of the escrows it creates; it acts
///   as the payee, the arbiter, and the backup arbiter via prank. Every
///   call is wrapped in try/catch — a revert is a legal outcome (wrong
///   actor, wrong window, unstaked bond), the invariants are about
///   state consistency, not about calls succeeding. Release / refund /
///   refundAfterRejection attempts record whether they ever SUCCEEDED
///   while the escrow was escalated (or challenge-open) — the property
///   the invariant asserts never happens.
contract EscrowDisputeInvariantHandler is Test {
    LamplightEscrow public esc;
    address public payee = address(0xBEEF);
    address public arbiterAddr = address(0xA9B17E9);
    address public backupAddr = address(0xBAC4);
    address public third = address(0xCAFE);
    uint256[] public ids;
    bool public releaseSucceededWhileEscalated;
    bool public refundSucceededWhileEscalated;
    bool public refundAfterRejectionSucceededWhileEscalated;
    bool public releaseSucceededWhileChallengeOpen;

    constructor(LamplightEscrow esc_) {
        esc = esc_;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (ids.length == 0) return type(uint256).max; // sentinel: no escrow yet
        return ids[seed % ids.length];
    }

    function create(uint256 amount, uint256 deadlineIn, uint256 bond, uint256 withBackup) external {
        amount = bound(amount, 1, 0.01 ether);
        deadlineIn = bound(deadlineIn, 1 days, 30 days);
        bond = bound(bond, 0, 0.01 ether);
        address backup = withBackup % 2 == 0 ? backupAddr : address(0);
        try esc.createEscrow{value: amount}(
            payee,
            block.timestamp + deadlineIn,
            arbiterAddr,
            backup,
            uint96(bond)
        ) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function deliver(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        vm.prank(payee);
        try esc.deliver(id, keccak256(abi.encode(seed))) {} catch {}
    }

    function reject(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.rejectDelivery(id) {} catch {}
    }

    function stakeBond(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        uint256 bond = esc.getEscrow(id).bondAmount;
        vm.prank(arbiterAddr);
        try esc.stakeBond{value: bond}(id) {} catch {}
    }

    function escalate(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.escalateDispute(id) {} catch {}
    }

    function resolve(uint256 seed, bool toPayee) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        address resolver = esc.getEscrow(id).challenged ? backupAddr : arbiterAddr;
        vm.prank(resolver);
        try esc.resolveDispute(id, toPayee) {} catch {}
    }

    function timeout(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.resolveDisputeTimeout(id) {} catch {}
    }

    function reEscalate(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.reEscalate(id) {} catch {}
    }

    function finalize(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        try esc.finalizeResolution(id) {} catch {}
    }

    function release(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        bool wasEscalated = esc.getEscrow(id).escalated;
        bool wasChallengeOpen = esc.getEscrow(id).challengeOpen;
        try esc.release(id) {
            if (wasEscalated) releaseSucceededWhileEscalated = true;
            if (wasChallengeOpen) releaseSucceededWhileChallengeOpen = true;
        } catch {}
    }

    function releaseAsPayee(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        bool wasEscalated = esc.getEscrow(id).escalated;
        bool wasChallengeOpen = esc.getEscrow(id).challengeOpen;
        vm.prank(payee);
        try esc.release(id) {
            if (wasEscalated) releaseSucceededWhileEscalated = true;
            if (wasChallengeOpen) releaseSucceededWhileChallengeOpen = true;
        } catch {}
    }

    function refund(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        bool wasEscalated = esc.getEscrow(id).escalated;
        try esc.refund(id) {
            if (wasEscalated) refundSucceededWhileEscalated = true;
        } catch {}
    }

    function refundAfterRejection(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == type(uint256).max) return;
        bool wasEscalated = esc.getEscrow(id).escalated;
        try esc.refundAfterRejection(id) {
            if (wasEscalated) refundAfterRejectionSucceededWhileEscalated = true;
        } catch {}
    }

    function withdraw() external {
        try esc.withdraw() {} catch {}
    }

    receive() external payable {}
}

/// @notice Invariant tests for the dispute lifecycle (round 2):
///   (1) no settlement path — release (as payer or payee), refund,
///   refundAfterRejection — may ever succeed while an escrow is
///   escalated, and release may never succeed while a challenge is
///   open; (2) the balance invariant extended to bonds — the contract
///   holds exactly the unsettled escrow amounts plus the staked bonds
///   on unsettled escrows plus all outstanding pull credits.
contract LamplightEscrowDisputeInvariantTest is Test {
    LamplightEscrow esc;
    EscrowDisputeInvariantHandler handler;

    function setUp() public {
        esc = new LamplightEscrow();
        handler = new EscrowDisputeInvariantHandler(esc);
        vm.deal(address(handler), 100 ether);
        vm.deal(handler.arbiterAddr(), 10 ether);
        targetContract(address(handler));
    }

    function invariant_NoSettlementWhileEscalated() public view {
        assertFalse(handler.releaseSucceededWhileEscalated());
        assertFalse(handler.refundSucceededWhileEscalated());
        assertFalse(handler.refundAfterRejectionSucceededWhileEscalated());
        assertFalse(handler.releaseSucceededWhileChallengeOpen());
    }

    function invariant_BalanceHoldsWithBonds() public view {
        uint256 expected;
        for (uint256 i = 0; i < handler.idsLength(); ++i) {
            LamplightEscrow.Escrow memory e = esc.getEscrow(handler.ids(i));
            if (!e.settled) {
                expected += e.amount;
                if (e.bondStaked) expected += e.bondAmount;
            }
        }
        expected += esc.pendingWithdrawals(address(handler));
        expected += esc.pendingWithdrawals(handler.payee());
        expected += esc.pendingWithdrawals(handler.third());
        expected += esc.pendingWithdrawals(handler.arbiterAddr());
        expected += esc.pendingWithdrawals(handler.backupAddr());
        assertEq(address(esc).balance, expected);
    }
}
