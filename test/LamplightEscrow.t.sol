// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
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

    function setUp() public {
        esc = new LamplightEscrow();
        vm.deal(payer, 100 ether);
        vm.deal(payee, 1 ether);
        vm.deal(third, 1 ether);
    }

    function _create(uint256 amount, uint256 deadlineIn) internal returns (uint256) {
        vm.prank(payer);
        return esc.createEscrow{value: amount}(payee, block.timestamp + deadlineIn);
    }

    // ---- The 14 required cases, adapted to pull semantics ----

    function testCreateEscrowLocksFunds() public {
        uint256 id = _create(0.5 ether, 1 days);
        LamplightEscrow.Escrow memory e = esc.getEscrow(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.amount, 0.5 ether);
        assertFalse(e.delivered);
        assertFalse(e.settled);
        assertEq(address(esc).balance, 0.5 ether);
    }

    function testFullHappyPathRelease() public {
        uint256 id = _create(0.5 ether, 1 days);
        bytes32 h = keccak256("deliverable: bounty report v1");
        vm.prank(payee);
        esc.deliver(id, h);
        assertTrue(esc.getEscrow(id).delivered);

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
        // Finding 5: for any value and any shares summing to 10000, the
        // first n-1 recipients get exactly floor(value * share / 10000),
        // the last takes the dust, the split sums to value, and nothing
        // is left in the contract.
        value = bound(value, 1, 10 ether);
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

        uint256 b0 = payee.balance;
        uint256 b1 = third.balance;
        uint256 b2 = payer.balance;
        vm.prank(payer);
        esc.splitPayment{value: value}(r, s);

        uint256 got0 = payee.balance - b0;
        uint256 got1 = third.balance - b1;
        uint256 got2 = (payer.balance + value) - b2;

        assertEq(got0, (value * s0) / 10000);
        assertEq(got1, (value * s1) / 10000);
        assertEq(got2, value - got0 - got1);
        assertEq(got0 + got1 + got2, value);
        assertEq(esc.pendingWithdrawals(payee), 0);
        assertEq(esc.pendingWithdrawals(third), 0);
        assertEq(esc.pendingWithdrawals(payer), 0);
        assertEq(address(esc).balance, 0);
    }
}
