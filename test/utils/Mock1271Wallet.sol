// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Mock1271Wallet — TEST ONLY.
/// @notice A contract wallet that answers ERC-1271 `isValidSignature` according to a configurable mode, used as a
///         curator. The signature bytes are ignored; the wallet decides per digest.
/// @dev `isValidSignature` is deliberately not `view`, so the Reenter modes can attempt state-changing calls. The
///      authorization module calls it through `staticcall`, so any such attempt reverts inside the wallet. The wallet
///      also forwards arbitrary calls (`exec`) so it can act as the curator for vault calls such as
///      `cancelAllocation` and `bumpGeneration`.
contract Mock1271Wallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    enum Mode {
        Approve, // MAGIC for approved digests, 0xffffffff otherwise
        WrongValue, // always a wrong 4-byte value
        Revert, // always reverts
        ShortReturn, // returns 1 byte
        BurnGas, // loops until out of gas
        ReturnBomb, // returns 1 MB of data starting with MAGIC
        ReenterSwallow, // tries `target.call(payload)`, ignores the failure, then answers as Approve
        ReenterStrict // tries `target.call(payload)` and reverts if it fails
    }

    Mode public mode;
    mapping(bytes32 digest => bool) public approved;
    address public target;
    bytes public payload;

    function setMode(Mode m) external {
        mode = m;
    }

    function approve(bytes32 digest, bool ok) external {
        approved[digest] = ok;
    }

    function setReentry(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function isValidSignature(bytes32 digest, bytes calldata) external returns (bytes4) {
        Mode m = mode;
        if (m == Mode.WrongValue) return 0xdeadbeef;
        if (m == Mode.Revert) revert("wallet: no");
        if (m == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, shl(248, 0x16))
                return(0, 1)
            }
        }
        if (m == Mode.BurnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        if (m == Mode.ReturnBomb) {
            assembly ("memory-safe") {
                mstore(0, MAGIC)
                return(0, 1000000)
            }
        }
        if (m == Mode.ReenterSwallow || m == Mode.ReenterStrict) {
            (bool ok,) = target.call(payload);
            if (!ok && m == Mode.ReenterStrict) revert("wallet: reentry failed");
        }
        return approved[digest] ? MAGIC : bytes4(0xffffffff);
    }
}
