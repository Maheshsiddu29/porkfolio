// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ModuleCandidate — TEST ONLY.
/// @notice A contract offered to `setAuthModule` whose answer to `vault()` is configurable, used to show which answers
///         the vault's installation check accepts. It has no other module behaviour: it never calls `reserveFor`.
/// @dev `vault()` is served by the fallback so the test controls the exact returned bytes, including answers no
///      Solidity getter could produce (a short answer, dirty upper bits, a second word). Every other selector except
///      `set` reverts.
contract ModuleCandidate {
    bytes4 internal constant VAULT_SELECTOR = 0xfbfa77cf; // vault()

    enum Mode {
        Answer, // returns `word` as one 32-byte word
        Revert, // reverts
        Empty, // returns no data
        Short, // returns the first 31 bytes of `word`
        Long, // returns `word` followed by a second word
        BurnGas // loops until out of gas
    }

    Mode public mode;
    bytes32 public word;

    function set(Mode m, bytes32 w) external {
        mode = m;
        word = w;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (msg.sig != VAULT_SELECTOR) revert("candidate: unknown function");
        Mode m = mode;
        bytes32 w = word;
        if (m == Mode.Revert) revert("candidate: no");
        if (m == Mode.Empty) return "";
        if (m == Mode.Short) return abi.encodePacked(bytes31(w));
        if (m == Mode.Long) return abi.encode(w, bytes32(type(uint256).max));
        if (m == Mode.BurnGas) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        return abi.encode(w);
    }
}
