// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceRiskAdapter} from "../../src/oracle/PriceRiskAdapter.sol";
import {IMarketRiskAdapter} from "../../src/interfaces/IMarketRiskAdapter.sol";

interface IChainlinkRounds {
    function latestRound() external view returns (uint256);
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3PoolObserve {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IPythUnsafe {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/// @notice Read-only experiment against Unichain mainnet (chain 130): the real feeds, a `PriceRiskAdapter` deployed on
///         the local fork, and the gas of every read. Nothing is broadcast; the fork is local to this test run.
/// @dev Skipped unless UNICHAIN_RPC_URL is set, e.g.
///        UNICHAIN_RPC_URL=https://mainnet.unichain.org forge test --match-contract UnichainOraclesForkTest -vv
///      Addresses: Chainlink from its reference-data directory (feeds-ethereum-mainnet-unichain-1.json), RedStone
///      from its relayer manifest (unichainMultiFeed.json), Pyth from its contract-manager store. Every one was checked
///      with on-chain calls before being written here (docs/architecture/ORACLE_VERIFICATION_UNICHAIN.md).
contract UnichainOraclesForkTest is Test {
    address internal constant CL_ETH_USD = 0xBcE70e194940a157f3A80566505a7E96f5238CCa;
    address internal constant CL_USDC_USD = 0xbd1cD1518eFB92a92100da62D4C488c810dFd75b;
    address internal constant CL_SEQUENCER = 0x495639D9914e7D270c5dCC641BfB1d807423F813;
    address internal constant RS_ETH = 0xe8D9FbC10e00ecc9f0694617075fDAF657a76FB2;
    address internal constant RS_USDC = 0xD15862FC3D5407A03B696548b6902D6464A69b8c;
    address internal constant PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    address internal constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 internal constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    /// @dev Uniswap v3 WETH/USDC 0.3% pool on Unichain (deepest v3 pool for the pair at the time of writing; factory
    ///      0x1f98...0003 from Uniswap's Unichain address page).
    address internal constant V3_WETH_USDC_3000 = 0x8927058918e3CFf6F55EfE45A58db1be1F069E49;

    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
    }

    function _gasLatest(address feed) internal view returns (uint256 g, int256 answer, uint256 updatedAt) {
        g = gasleft();
        (, answer,, updatedAt,) = IAggregatorV3(feed).latestRoundData();
        g -= gasleft();
    }

    /// @notice Each feed answers, with its age; cold-read gas logged.
    function test_fork_feedsAnswerAndGas() public {
        if (!live) vm.skip(true);
        assertEq(block.chainid, 130);
        address[5] memory feeds = [CL_ETH_USD, CL_USDC_USD, RS_ETH, RS_USDC, CL_SEQUENCER];
        string[5] memory names =
            ["Chainlink ETH/USD", "Chainlink USDC/USD", "RedStone ETH", "RedStone USDC", "sequencer"];
        for (uint256 k; k < 5; ++k) {
            (uint256 g, int256 a, uint256 t) = _gasLatest(feeds[k]);
            emit log_named_uint(string.concat(names[k], " latestRoundData cold gas"), g);
            emit log_named_int(string.concat(names[k], " answer"), a);
            emit log_named_uint(string.concat(names[k], " age (s)"), block.timestamp - t);
            if (k < 4) assertGt(a, 0);
        }
    }

    /// @notice Chainlink exposes round history (for a realized-volatility term); RedStone does not.
    function test_fork_roundHistory() public {
        if (!live) vm.skip(true);
        uint256 rid = IChainlinkRounds(CL_ETH_USD).latestRound();
        uint256 g = gasleft();
        for (uint256 k = 1; k <= 4; ++k) {
            // forge-lint: disable-next-line(unsafe-typecast) Chainlink round ids are uint80.
            IChainlinkRounds(CL_ETH_USD).getRoundData(uint80(rid - k));
        }
        emit log_named_uint("Chainlink ETH/USD 4 x getRoundData gas", g - gasleft());
        vm.expectRevert();
        IChainlinkRounds(RS_ETH).getRoundData(0);
    }

    /// @notice Pyth's stored price on Unichain is only as fresh as the last transaction that pushed an update; without
    ///         an update in the same transaction it is not a usable reference.
    function test_fork_pythStoredPriceAge() public {
        if (!live) vm.skip(true);
        uint256 g = gasleft();
        IPythUnsafe.Price memory p = IPythUnsafe(PYTH).getPriceUnsafe(PYTH_ETH_USD);
        emit log_named_uint("Pyth getPriceUnsafe cold gas", g - gasleft());
        emit log_named_uint("Pyth stored ETH/USD age (s)", block.timestamp - p.publishTime);
    }

    /// @notice The adapter on the real feeds: WETH/USDC pool (currency0 USDC, 6 decimals; currency1 WETH, 18),
    ///         Chainlink and RedStone as the two sources, the sequencer feed with a one-hour grace. Deviation thresholds
    ///         as published (30 / 50 / 50 / 50 bps) plus 1 bp latency margin; staleness = heartbeat + 30 minutes.
    function test_fork_adapterReadingAndGas() public {
        if (!live) vm.skip(true);
        PriceRiskAdapter a = new PriceRiskAdapter(
            PriceRiskAdapter.Source(IAggregatorV3(CL_USDC_USD), IAggregatorV3(CL_ETH_USD), 3100, 5100, 88_200, 88_200),
            PriceRiskAdapter.Source(IAggregatorV3(RS_USDC), IAggregatorV3(RS_ETH), 5100, 5100, 12_600, 23_400),
            USDC,
            WETH,
            6,
            18,
            IAggregatorV3(CL_SEQUENCER),
            3600,
            2
        );
        vm.cool(CL_USDC_USD);
        vm.cool(CL_ETH_USD);
        vm.cool(RS_USDC);
        vm.cool(RS_ETH);
        vm.cool(CL_SEQUENCER);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(a).staticcall(abi.encodeCall(a.currentReference, ()));
        uint256 used = g - gasleft();
        emit log_named_uint("adapter.currentReference gas (feeds cold)", used);
        if (!ok) {
            emit log_named_bytes("adapter refused (revert data)", ret);
            return;
        }
        IMarketRiskAdapter.Reading memory r = abi.decode(ret, (IMarketRiskAdapter.Reading));
        emit log_named_uint("mid, raw WETH per raw USDC (integer part)", r.priceX96 >> 96);
        emit log_named_uint("uncertainty (pips)", r.uncertaintyPips);
        emit log_named_uint("valid for (s)", r.validUntil - block.timestamp);
        emit log_named_uint("live sources", r.liveSources);
        g = gasleft();
        a.currentReference();
        emit log_named_uint("adapter.currentReference gas (warm)", g - gasleft());
    }

    /// @notice A 30-minute TWAP from the Uniswap v3 pool: an on-chain reference that shares no upstream with the push
    ///         feeds (its source is trading on Unichain itself). Logs the read gas and the TWAP tick; the pool is thin,
    ///         so this is a coarse cross-check, not a price to quote around.
    function test_fork_v3Twap() public {
        if (!live) vm.skip(true);
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        uint256 g = gasleft();
        (int56[] memory ticks,) = IUniswapV3PoolObserve(V3_WETH_USDC_3000).observe(ago);
        emit log_named_uint("v3 observe([1800, 0]) cold gas", g - gasleft());
        int256 twapTick = (int256(ticks[1]) - int256(ticks[0])) / 1800;
        emit log_named_int("v3 30-min TWAP tick (raw WETH per raw USDC = 1.0001^tick)", twapTick);
        assertGt(twapTick, 190_000);
        assertLt(twapTick, 210_000);
    }
}
