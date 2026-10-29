// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Shared log-scanning helpers for the LamplightEscrow tests
///   (round 5, Oct 27, 2026, Grok improvement): _findBondSettled and
///   _findDisputeTimedOut were duplicated between the main test contract
///   and the dispute invariant test contract — same bodies, two copies
///   that could drift. They live here now, as one abstract contract
///   both test contracts inherit, so the scanners stay in sync by
///   construction. Behaviour is identical to the round-3 / round-4
///   originals: the bond settlement / timeout event is never the first
///   event of its call (release / refund / Refunded emits first), so
///   expectEmit cannot target it — read the raw log instead.
abstract contract LogScanners {
    /// @dev Scan recorded logs for the single BondSettled event and
    ///   decode it.
    function _findBondSettled(Vm.Log[] memory logs)
        internal
        pure
        returns (bool found, address recipient, uint256 amount, bool forfeited)
    {
        bytes32 sig = keccak256("BondSettled(uint256,address,uint256,bool)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (amount, forfeited) = abi.decode(logs[i].data, (uint256, bool));
                recipient = address(uint160(uint256(logs[i].topics[2])));
                return (true, recipient, amount, forfeited);
            }
        }
        return (false, address(0), 0, false);
    }

    /// @dev Scan recorded logs for the DisputeTimedOut event and decode
    ///   its bond outcome (round 4).
    function _findDisputeTimedOut(Vm.Log[] memory logs)
        internal
        pure
        returns (bool found, address caller, uint256 bondAmount, bool bondForfeited)
    {
        bytes32 sig = keccak256("DisputeTimedOut(uint256,address,uint256,bool)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (bondAmount, bondForfeited) = abi.decode(logs[i].data, (uint256, bool));
                caller = address(uint160(uint256(logs[i].topics[2])));
                return (true, caller, bondAmount, bondForfeited);
            }
        }
        return (false, address(0), 0, false);
    }

    /// @dev Scan recorded logs for the DisputeResolved event and decode
    ///   its bond outcome (round 6): releasedToPayee, bondAmount and
    ///   bondForfeited are the data fields; the arbiter is topic 2.
    ///   On the deferred (challenge-open) path the bond fields carry
    ///   the 0 / false convention — no bond is settled in that call.
    function _findDisputeResolved(Vm.Log[] memory logs)
        internal
        pure
        returns (
            bool found,
            address arbiter,
            bool releasedToPayee,
            uint256 bondAmount,
            bool bondForfeited
        )
    {
        bytes32 sig = keccak256("DisputeResolved(uint256,address,bool,uint256,bool)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (releasedToPayee, bondAmount, bondForfeited) = abi.decode(
                    logs[i].data,
                    (bool, uint256, bool)
                );
                arbiter = address(uint160(uint256(logs[i].topics[2])));
                return (true, arbiter, releasedToPayee, bondAmount, bondForfeited);
            }
        }
        return (false, address(0), false, 0, false);
    }
}
