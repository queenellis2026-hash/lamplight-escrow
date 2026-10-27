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
        // The packed struct (uint96 amount, uint64 deadline/deliveredAt/
        // rejectedAt, deliveredAt != 0 as the delivered flag) must read
        // back exactly what createEscrow stored.
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
        // A deadline past 2**64 seconds cannot fit the packed uint64 slot.
        vm.prank(payer);
        vm.expectRevert("Invalid deadline");
        esc.createEscrow{value: 0.1 ether}(payee, uint256(type(uint64).max) + 1);
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
        // The payee does not cure within the 3-day cure window; the payer
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
        vm.warp(rejectedAt + 3 days); // cure window over
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

    function testRejectThenCureThenRejectAgain() public {
        // A cured delivery can be rejected again if the new hash is also
        // junk — each rejection starts a fresh cure window.
        uint256 id = _delivered(0.5 ether);
        vm.prank(payer);
        esc.rejectDelivery(id);
        vm.prank(payee);
        esc.deliver(id, keccak256("work v2 still junk"));
        vm.prank(payer);
        esc.rejectDelivery(id);
        assertEq(esc.getEscrow(id).rejectedAt, block.timestamp);
        // and the second rejection can also be cured
        vm.prank(payee);
        esc.deliver(id, keccak256("work v3 good"));
        vm.prank(payer);
        esc.release(id);
        assertTrue(esc.getEscrow(id).settled);
    }
}
