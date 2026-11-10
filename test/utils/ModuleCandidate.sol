// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AUTH_MODULE_ID} from "../../src/interfaces/ISharedCommitmentVault.sol";

/// @title ModuleCandidate — TEST ONLY.
/// @notice A contract offered to `setAuthModule` whose answers to `authModuleId()` and `vault()` are configurable,
///         used to show which answers the vault's installation check accepts. It has no other module behaviour: it
///         never calls `reserveFor`.
/// @dev Both getters are served by the fallback so the test controls the exact returned bytes, including answers no
///      Solidity getter could produce (a short answer, dirty upper bits, a second word, the call data echoed back).
///      By default `authModuleId()` answers AUTH_MODULE_ID, so a test that configures only `vault()` exercises the
///      vault binding alone. With `sameAnswerForAll` set, the `vault()` reply is served for every selector, which
///      models a fallback that answers anything with one fixed word. Every other selector except the setters
///      reverts.
contract ModuleCandidate {
    bytes4 internal constant VAULT_SELECTOR = 0xfbfa77cf; // vault()
    bytes4 internal constant ID_SELECTOR = 0x31b014a1; // authModuleId()

    enum Mode {
        Answer, // returns `word` as one 32-byte word
        Revert, // reverts with an Error(string)
        RevertWord, // reverts with exactly `word` as revert data
        Empty, // returns no data
        Short, // returns the first 31 bytes of `word`
        Long, // returns `word` followed by a second word
        BurnGas, // loops until out of gas
        Echo // returns the call data it received (the 4-byte selector)
    }

    Mode public mode;
    bytes32 public word;
    Mode public idMode;
    bytes32 public idWord = AUTH_MODULE_ID;
    bool public sameAnswerForAll;

    /// @notice Configure the answer to `vault()`.
    function set(Mode m, bytes32 w) external {
        mode = m;
        word = w;
    }

    /// @notice Configure the answer to `authModuleId()`.
    function setId(Mode m, bytes32 w) external {
        idMode = m;
        idWord = w;
    }

    /// @notice When true, every selector gets the `vault()` answer.
    function setSameAnswerForAll(bool on) external {
        sameAnswerForAll = on;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        Mode m;
        bytes32 w;
        if (sameAnswerForAll || msg.sig == VAULT_SELECTOR) {
            (m, w) = (mode, word);
        } else if (msg.sig == ID_SELECTOR) {
            (m, w) = (idMode, idWord);
        } else {
            revert("candidate: unknown function");
        }
        if (m == Mode.Revert) revert("candidate: no");
        if (m == Mode.RevertWord) {
            assembly ("memory-safe") {
                mstore(0, w)
                revert(0, 32)
            }
        }
        if (m == Mode.Empty) return "";
        if (m == Mode.Short) return abi.encodePacked(bytes31(w));
        if (m == Mode.Long) return abi.encode(w, bytes32(type(uint256).max));
        if (m == Mode.Echo) return msg.data;
        if (m == Mode.BurnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        return abi.encode(w);
    }
}
