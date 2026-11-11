"""Matched synthetic simulation of the market-making candidates on a model of the shared vault.

Run from the repository root:
    python3 simulations/mm/simulate.py            # held-out worlds, all candidates, writes simulations/mm/results/
    python3 simulations/mm/simulate.py --calibrate  # parameter grid for candidate C on the calibration worlds only

SYNTHETIC ONLY. Every market path, oracle update, order, size and arrival time is generated here from the stated
distributions with fixed seeds. Nothing is historical Uniswap data and nothing here estimates real revenue. The
results compare pricing rules under one set of explicit assumptions (`docs/architecture/PHASE1B4_REPORT.md` §5).

What is modelled
----------------
- Market: log-price random walk on a 10 s grid (one "block" per slot), with regime drift, volatility and jumps.
  `mkt` is raw currency1 per raw currency0 (the hooks' price convention); both tokens have 18 decimals.
- Oracles: a primary push feed (deviation threshold + heartbeat, one slot of latency) and a secondary push feed with
  a wider threshold, a longer heartbeat and independent reporting noise. Stress worlds add outages and manipulation.
- Vault: N_0, N_1, shares S; D14 floors as a pivot K; one allocation per direction refreshed every 6 h to
  min(target, admissible), consumed by trades; a daily gross-output flow cap per asset; in-kind pro-rata LP exits
  that need free inventory (N_a - Q_a) in both assets. Floors, quota and flow caps are checked on the exact integers
  the vault would see.
- Traders: uninformed orders (persistent direction, lognormal size, lognormal cost tolerance against an outside
  venue, optional same-block splitting); informed orders (they know the market 10 minutes ahead and trade only with
  an edge); one arbitrageur who trades against the true market whenever a quote beats it by more than its cost.
- Candidates: A (production Hook B), B (Hook B curve plus spread, two settings), C (inventory potential with an
  oracle reference), C-static (C's pricing on the static reference, to separate the oracle's contribution), C with
  static floors (to measure the cost of floors that do not follow the reference), D (C plus an RFQ fallback).

What is not modelled: gas, MEV ordering beyond the single arbitrageur, multiple curators, real LP behaviour, and any
historical distribution. The inventory target for every metric is the seeding composition per share.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import statistics
import sys
import zlib
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass, field, replace

sys.path.insert(0, os.path.dirname(__file__))

from model import HookA, HookAConfig  # noqa: E402
from model import (  # noqa: E402
    ext_cost,
    inventory_state,
    straddle_cap,
    PIPS,
    Q96,
    WAD,
    FeedReading,
    HookB,
    HookBConfig,
    InventoryConfig,
    Reference,
    ReferencePolicy,
    Revert,
    TwoSidedCurve,
    TwoSidedCurveConfig,
    VaultSnapshot,
    depth_per_share_for,
    floor_ok,
    floors_from_pivot,
    mul_div,
    mul_div_up,
    quote_inventory,
    resolve_reference,
    BracketSource,
    ActivityFeeConfig,
    bracket_reference,
    core_state,
    decayed,
    hook_a_quote,
    hook_b_quote,
)

E18 = 10**18
SLOT = 10  # seconds per grid step
INIT = 1_000_000  # tokens of each asset at seeding
MARKOUT = 600  # seconds

# ------------------------------------------------------------------------------------------------------------------
# Worlds
# ------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Regime:
    name: str
    days: float = 14.0
    mean_gap: float = 90.0  # seconds between orders
    vol_day: float = 0.015  # daily log-price volatility
    drift_day: float = 0.0  # daily log drift of mkt (currency1 per currency0)
    jumps: tuple = ()  # (fraction of run, log jump)
    persist: float = 0.5
    median: float = 1500.0  # tokens of currency0 value
    sigma: float = 1.0
    whale_p: float = 0.0
    whale_median: float = 40_000.0
    split_p: float = 0.0
    split_n: tuple = (5, 20)
    informed: float = 0.20
    tol_median_bps: float = 30.0
    withdraw_frac: float = 0.0  # fraction of shares requested over the run
    oracle_dev: float = 0.002  # primary deviation threshold
    oracle_hb: int = 3600
    sec_dev: float = 0.005
    sec_hb: int = 86_400
    sec_noise_bps: float = 2.0
    outage: tuple = ()  # (start fraction, seconds) primary returns nothing
    manip_primary: tuple = ()  # (start fraction, seconds, log offset)
    manip_secondary: tuple = ()
    scale: float = 1.0  # vault size relative to INIT (illiquid regime: 0.1)
    freeze: tuple = ()  # (start fraction, seconds): both verified push feeds publish nothing (still within max age)


REGIMES = [
    Regime("calm balanced"),
    Regime("one-sided flow", persist=0.85),
    Regime("whales", whale_p=0.03),
    Regime("splitters", split_p=0.5),
    Regime("volatile", vol_day=0.05),
    Regime("trend", drift_day=-0.015, vol_day=0.02),
    Regime("jump and partial recovery", vol_day=0.01, jumps=((0.3, math.log(0.94)), (0.6, math.log(1.03)))),
    Regime("LP withdrawals + one-sided", persist=0.8, withdraw_frac=0.5),
]

STRESS = [
    Regime("primary outage 6 h in volatility", days=3, vol_day=0.05, outage=((0.4, 6 * 3600),)),
    Regime("primary manipulated +3% for 30 min", days=3, manip_primary=((0.5, 1800, math.log(1.03)),)),
    Regime("both feeds manipulated +3% for 30 min", days=3,
           manip_primary=((0.5, 1800, math.log(1.03)),), manip_secondary=((0.5, 1800, math.log(1.03)),)),
    Regime("depeg -15% in 1 h then drift", days=3, vol_day=0.03, drift_day=-0.03,
           jumps=tuple((0.3 + i * 0.0005, math.log(0.85) / 30) for i in range(30))),
]

ILLIQUID = Regime("illiquid (vault 10x smaller)", scale=0.1)
REGIMES_141 = REGIMES + [ILLIQUID]

CALIBRATION_SEEDS = (101, 102, 103, 104)
HELD_OUT_SEEDS = (201, 202, 203, 204)


@dataclass
class Order:
    slot: int
    informed: bool
    zfo: bool  # trader sells currency0
    value: float  # tokens of currency0
    pieces: int
    tol_bps: float


@dataclass
class World:
    regime: Regime
    seed: int
    mkt: list  # float, per slot
    prim: list  # (price_x96, updated_at) per slot, price 0 = unavailable
    sec: list
    orders: list
    withdrawals: list  # (slot, fraction of then-outstanding shares)
    vprim: list = field(default_factory=list)  # verified-parameter primary (Chainlink-like) per slot
    vsec: list = field(default_factory=list)  # verified-parameter secondary (RedStone-like) per slot
    pull: list = field(default_factory=list)  # hypothetical fresh pull source per slot
    _rounds: list = field(default_factory=list)  # (first slot visible, FeedReading) of every primary round

    def prim_hist(self, k: int, n: int) -> list:
        """The last n primary rounds visible at slot k (oldest first), as a contract would read them by round id."""
        if not self._rounds:
            last = None
            for i, r in enumerate(self.prim):
                if r[0] and r != last:
                    self._rounds.append((i, FeedReading(*r)))
                    last = r
        import bisect
        j = bisect.bisect_right(self._rounds, k, key=lambda e: e[0])
        return [r for _, r in self._rounds[max(0, j - n):j]]


def _x96(p: float) -> int:
    return int(p * Q96)


def build_world(reg: Regime, seed: int) -> World:
    rng = random.Random(seed * 1_000_003 + zlib.crc32(reg.name.encode()))
    n = int(reg.days * 86_400 / SLOT)
    dt = SLOT / 86_400
    sd = reg.vol_day * math.sqrt(dt)
    jumps = {int(f * n): j for f, j in reg.jumps}
    lp, mkt = 0.0, []
    for k in range(n):
        lp += reg.drift_day * dt + rng.gauss(0, sd) + jumps.get(k, 0.0)
        mkt.append(math.exp(lp))

    def feed(dev, hb, noise_bps, manip, outage, rng_f):
        out, last_val, last_t, pending = [], None, -10**9, None
        mwin = [(int(f * n), int(f * n) + s // SLOT, off) for f, s, off in manip]
        owin = [(int(f * n), int(f * n) + s // SLOT) for f, s in outage]
        cur = (0, 0)
        for k in range(n):
            if pending is not None:  # one slot of latency
                cur, pending = pending, None
            obs = math.log(mkt[k]) + (rng_f.gauss(0, noise_bps * 1e-4) if noise_bps else 0.0)
            for a, b, off in mwin:
                if a <= k < b:
                    obs += off
            if last_val is None or abs(obs - last_val) > math.log1p(dev) or (k * SLOT - last_t) >= hb:
                last_val, last_t = obs, k * SLOT
                pending = (_x96(math.exp(obs)), (k + 1) * SLOT)
            down = any(a <= k < b for a, b in owin)
            out.append((0, 0) if down else cur)
        return out

    prim = feed(reg.oracle_dev, reg.oracle_hb, 0.0, reg.manip_primary, reg.outage, random.Random(seed + 1))
    sec = feed(reg.sec_dev, reg.sec_hb, reg.sec_noise_bps, reg.manip_secondary, (), random.Random(seed + 2))
    # Verified Unichain parameters (docs/architecture/ORACLE_VERIFICATION_UNICHAIN.md): both push providers update the
    # ETH leg on a 0.5% deviation; heartbeats 24 h (Chainlink) and 6 h (RedStone). The USDC legs barely move, so the
    # pair moves with the ETH leg; their thresholds widen the bracket (VERIFIED_BRACKET), not the update rule.
    vprim = feed(0.005, 86_400, 0.0, reg.manip_primary, reg.outage, random.Random(seed + 3))
    vsec = feed(0.005, 21_600, reg.sec_noise_bps, reg.manip_secondary, (), random.Random(seed + 4))
    for fs, fdur in reg.freeze:  # a frozen feed keeps showing its last answer and timestamp
        a, b = int(fs * n), min(n, int(fs * n) + fdur // SLOT)
        for lst in (vprim, vsec):
            for k in range(a + 1, b):
                lst[k] = lst[a]
    # Hypothetical pull source: the market one slot ago, every slot (not verified usable on Unichain: see the report).
    pull = [(0, 0)] + [(_x96(mkt[k - 1]), (k - 1) * SLOT) for k in range(1, n)]

    orders, t, zfo = [], 0.0, rng.random() < 0.5
    horizon = MARKOUT // SLOT
    while True:
        t += rng.expovariate(1 / reg.mean_gap)
        k = int(t / SLOT) + 1
        if k >= n - horizon:
            break
        informed = rng.random() < reg.informed
        med = reg.whale_median if rng.random() < reg.whale_p else reg.median
        value = max(1.0, rng.lognormvariate(math.log(med), reg.sigma))
        pieces = rng.randint(*reg.split_n) if rng.random() < reg.split_p else 1
        tol = rng.lognormvariate(math.log(reg.tol_median_bps), 0.6)
        if informed:
            d = mkt[k + horizon] / mkt[k]
            # currency1 appreciates (in currency0) when mkt (currency1 per currency0) falls: buy currency1.
            o = Order(k, True, d < 1.0, value, 1, 0.0)
        else:
            zfo = zfo if rng.random() < reg.persist else not zfo
            o = Order(k, False, zfo, value, pieces, tol)
        orders.append(o)
    withdrawals = []
    if reg.withdraw_frac:
        m = 20
        each = 1 - (1 - reg.withdraw_frac) ** (1 / m)
        for _ in range(m):
            withdrawals.append((rng.randrange(1, n - horizon), each))
        withdrawals.sort()
    return World(reg, seed, mkt, prim, sec, orders, withdrawals, vprim, vsec, pull)


# ------------------------------------------------------------------------------------------------------------------
# Candidates
# ------------------------------------------------------------------------------------------------------------------

V_TOKENS = 1_000_000  # depth used by A and B (the Phase 1B-3 fixture) and, per share, by C
REF_POLICY = ReferencePolicy(max_age=3900, max_divergence=10_000, secondary_max_age=90_000, require_secondary=False,
                             missing_penalty=1_000, age_widen=0)



def c_config(base_spread: int, max_deviation: int, min_edge: int = 100, max_spread: int = 12_000,
             band: bool = False) -> InventoryConfig:
    """Candidate C parameters with the depth derived from the risk cap (see `depth_per_share_for`)."""
    return InventoryConfig(target_per_share=WAD,
                           depth_per_share=depth_per_share_for(WAD, max_deviation, base_spread, min_edge),
                           depth_max=2**95 - 1, base_spread=base_spread, min_edge=min_edge, max_spread=max_spread,
                           max_deviation=max_deviation, band_edge=band)


C_DEFAULT = c_config(2_000, 300_000)


@dataclass(frozen=True)
class Candidate:
    name: str
    kind: str  # "A", "B", "C", "D", or "X" (several hooks on one reserve; see `hooks`)
    oracle: bool = False  # C/D: oracle reference; A/B: the keeper re-prices the hook from the primary feed
    floors: str = "static"  # "static" pivot at the seeding price, or "keeper" (re-centred on the primary)
    b_spread: int = 0
    b_impact: int = 20_000
    c: InventoryConfig = C_DEFAULT
    rfq_spread: int = 1_500  # D: RFQ maker's half-spread around the true market, pips
    rfq_avail: float = 0.95
    keeper_band: float = 0.001  # floors (and A/B prices) re-centred when the primary moves this far from the pivot
    keeper_delay: int = 60  # seconds between the trigger and the new floors taking effect
    vol_mult: int = 0  # C/D: realized-volatility widening multiplier, percent
    rfq_inventory_checked: bool = True  # D: RFQ fills must also respect the hook's inventory cap
    a_depth: int = V_TOKENS  # A: Hook B depth, tokens
    hooks: tuple = ()  # X: sub-candidates sharing the reserve; "hookA" = production Hook A
    ref_mode: str = "assumed"  # "assumed" (Phase 1B-4 feeds), "point" (verified feeds, divergence uncertainty),
    #                            "bracket" (verified feeds, fail-safe bracket), "bracket_pull" (+ hypothetical pull)
    strategy: str = "B"  # C/D/S: "B" core only (Hook B strategy) or "A" (Hook A activity fee on the core)
    kappa: int = 150_000  # floors="orb": vault inventory tolerance, pips (inventory floor = target * (1 - kappa))
    max_unc: int = 30_000  # floors="orb": vault uncertainty breaker, pips
    fresh_avail: float = 1.0  # bracket_pull: probability that a trade carries a fresh signed payload
    b_markup: int = 0  # strategy B: flat markup, pips


# Held-out candidates. A, B and C parameters are the calibration selections (results/calibration.json, rule in
# `calibrate`); the other rows remove one component of the selected C, or add the RFQ path, to attribute effects.
C_SELECTED = c_config(2_000, 150_000)
KEEPER = dict(oracle=True, floors="keeper")

# Bracket half-widths of the verified sources for a WETH/USDC-like pair, pips: each provider's ETH-leg threshold plus
# its USDC-leg threshold, plus 1 bp of latency margin per leg (the PriceRiskAdapter fork configuration).
VERIFIED_BRACKET = {"primary": (8_200, 86_400 + 1_800), "secondary": (10_200, 21_600 + 1_800), "pull": (1_500, 30)}
STRATEGY_A_FEE = ActivityFeeConfig(base=0, mx=2_000, scale0=20_000 * E18, scale1=20_000 * E18, window=3_600)
POINT_POLICY = replace(REF_POLICY, max_age=86_400 + 1_800, secondary_max_age=21_600 + 1_800)
CANDIDATES = [
    Candidate("A0 Hook B, static P", "A"),
    Candidate("A  Hook B, keeper P+floors", "A", **KEEPER),
    Candidate("B1 curve+20bps spread, 2% cap", "B", b_spread=2_000, b_impact=20_000, **KEEPER),
    Candidate("B2 curve+20bps spread, straddle cap", "B", b_spread=2_000, b_impact=2_000, **KEEPER),
    Candidate("C1 inventory, static floors", "C", oracle=True, c=C_SELECTED, vol_mult=50),
    Candidate("C2 inventory, no vol term", "C", c=C_SELECTED, vol_mult=0, **KEEPER),
    Candidate("C3 inventory (selected)", "C", c=C_SELECTED, vol_mult=50, **KEEPER),
    Candidate("D  C3 + RFQ, inventory-checked", "D", c=C_SELECTED, vol_mult=50, **KEEPER),
    Candidate("D' C3 + RFQ, unchecked", "D", c=C_SELECTED, vol_mult=50, rfq_inventory_checked=False, **KEEPER),
]

# Two hooks on one reserve, routed to the better quote (same worlds).
_C3 = CANDIDATES[6]
CROSS = [
    Candidate("X0 Hook A + Hook B (today)", "X", hooks=("hookA", CANDIDATES[1]), **KEEPER),
    Candidate("X1 Hook A + C3", "X", hooks=("hookA", _C3), **KEEPER),
    Candidate("X2 C3 + C-core 10bps (shared inventory)", "X",
              hooks=(_C3, replace(_C3, name="C 10bps", c=c_config(1_000, 150_000))), **KEEPER),
]

ARB_COST_BPS = 3.0
ALLOC_FRACTION = 0.30
REFRESH = 6 * 3600
BUFFER = 0.05
FLOW_CAP = 0.40  # of the seeding amount, per asset per day


class HookAEngine:
    """Production Hook A (cumulative flow fee at a reference price), re-priced by the keeper like A/B."""

    A_CFG = dict(base=500, mx=5_000, scale0=10_000 * E18, scale1=10_000 * E18, window=3600)

    def __init__(self, p0: int):
        self.h = HookA()
        self.h.configure(HookAConfig(p0, **self.A_CFG), 0)

    def quote(self, zfo, amt, now, snap, ref):
        out, _fee, lvl = self.h.quote(zfo, amt, now)
        return out, (zfo, lvl)

    def commit(self, tok, now):
        zfo, lvl = tok
        self.h.level[zfo], self.h.updated[zfo] = lvl, now

    def reprice(self, p, now):
        c = self.h.cfg
        self.h.configure(HookAConfig(p, c.base, c.mx, c.scale0, c.scale1, c.window), now)

    def save(self):
        return dict(self.h.level), dict(self.h.updated)

    def restore(self, st):
        self.h.level, self.h.updated = dict(st[0]), dict(st[1])


class MultiEngine:
    """Several hooks on one reserve. The router takes the best quote; the chosen hook's state is committed."""

    def __init__(self, engines):
        self.engines = engines
        self._ref_error = "ReferenceUnavailable"

    def quote(self, zfo, amt, now, snap, ref):
        best, err = None, None
        for i, e in enumerate(self.engines):
            try:
                out, tok = e.quote(zfo, amt, now, snap, ref if not isinstance(e, HookAEngine) else None)
            except Revert as x:
                err = x
                continue
            if best is None or out > best[0]:
                best = (out, (i, tok))
        if best is None:
            raise err
        return best

    def commit(self, tok, now):
        i, t = tok
        self.engines[i].commit(t, now)

    def reprice(self, p, now):
        for e in self.engines:
            if hasattr(e, "reprice") and not (isinstance(e, Engine) and e.cand.kind in ("C", "D")):
                e.reprice(p, now)

    def save(self):
        return [e.save() for e in self.engines]

    def restore(self, st):
        for e, x in zip(self.engines, st):
            e.restore(x)


class Engine:
    """Uniform quote/commit wrapper. `quote` returns (out, token) or raises Revert; `commit(token)` stores state."""

    def __init__(self, cand: Candidate, p0: int):
        self.cand, self.p0 = cand, p0
        self._ref_error = "ReferenceUnavailable"
        self.level = {True: 0, False: 0}
        self.updated = {True: 0, False: 0}
        if cand.kind == "A":
            self.h = HookB()
            self.h.configure(HookBConfig(p0, cand.a_depth * E18, 20_000, 3600), 0)
        elif cand.kind == "B":
            self.h = TwoSidedCurve(TwoSidedCurveConfig(p0, V_TOKENS * E18, cand.b_impact, 3600, cand.b_spread))

    def quote(self, zfo: bool, amt: int, now: int, snap: VaultSnapshot, ref: Reference | None):
        k = self.cand.kind
        if k == "A":
            out, x2, _ = self.h.quote(zfo, amt, now)
            return out, x2
        if k == "B":
            return self.h.quote(zfo, amt, now)
        if ref is None:
            raise Revert(getattr(self, "_ref_error", "ReferenceUnavailable"))
        if self.cand.strategy == "A":
            f = STRATEGY_A_FEE
            k = f.scale0 if zfo else f.scale1
            lvl = decayed(self.level[zfo], k, f.window, now - self.updated[zfo])
            q = hook_a_quote(core_state(self.cand.c, snap, ref), f, lvl, zfo, amt)
            return q.amount_out, ("A", zfo, q.new_level)
        if self.cand.b_markup:
            q = hook_b_quote(core_state(self.cand.c, snap, ref), self.cand.b_markup, PIPS - 1, zfo, amt)
            return q.amount_out, None
        q = quote_inventory(self.cand.c, snap, ref, zfo, amt)
        return q.amount_out, None

    def reprice(self, p: int, now: int):
        """A/B under a keeper: `configurePool` with the new reference, other parameters unchanged (decay applied)."""
        if self.cand.kind == "A":
            c = self.h.cfg
            self.h.configure(HookBConfig(p, c.depth, c.max_impact, c.window), now)
        elif self.cand.kind == "B":
            x = self.h.position_now(now)
            self.h.cfg = replace(self.h.cfg, price_x96=p)
            self.h.commit(x, now)

    def commit(self, token, now: int):
        if self.cand.kind == "A":
            self.h.x, self.h.updated = token, now
        elif self.cand.kind == "B":
            self.h.commit(token, now)
        elif token is not None and token[0] == "A":
            self.level[token[1]], self.updated[token[1]] = token[2], now

    def save(self):
        if self.cand.kind in ("A", "B"):
            return (self.h.x, self.h.updated)
        return ("S", dict(self.level), dict(self.updated))

    def restore(self, st):
        if st is None:
            return
        if st[0] == "S":
            self.level, self.updated = dict(st[1]), dict(st[2])
        else:
            self.h.x, self.h.updated = st


# ------------------------------------------------------------------------------------------------------------------
# Simulation
# ------------------------------------------------------------------------------------------------------------------


@dataclass
class Metrics:
    uninformed: int = 0
    uninformed_filled: int = 0
    uninformed_refused: int = 0  # refused by the hook or the vault (not by the trader)
    reverse: int = 0
    reverse_filled: int = 0
    informed: int = 0
    informed_filled: int = 0
    reasons: dict = field(default_factory=dict)
    exec_cost_bps_sum: float = 0.0  # uninformed fills, cost vs market weighted by value
    exec_value: float = 0.0
    spread_rev: float = 0.0  # LP revenue at the market at trade time, currency0 tokens
    markout: dict = field(default_factory=lambda: {"uninformed": 0.0, "informed": 0.0, "arb": 0.0, "rfq": 0.0})
    arb_rev: float = 0.0
    fills: int = 0
    notional: float = 0.0
    dev_sum: float = 0.0
    dev_n: int = 0
    dev_max: float = 0.0
    conc_max: float = 0.0
    lp_pnl_bps: float = 0.0
    final_dev: float = 0.0
    wd_requested: float = 0.0
    wd_instant: float = 0.0
    wd_wait_s: float = 0.0
    rfq_fills: int = 0
    days: float = 0.0
    value0: float = 0.0
    init: float = float(INIT)
    causes: dict = field(default_factory=dict)  # uninformed orders not filled, by the nine categories of the brief
    recoveries: list = field(default_factory=list)  # seconds from |deviation| > 10% back to < 5%


def _reason(m: Metrics, name: str):
    m.reasons[name] = m.reasons.get(name, 0) + 1


ORACLE_REASONS = {"UncertaintyTooHigh", "ReferenceUnavailable", "StaleReference", "ReferenceDivergence", "SecondaryUnavailable",
                  "SpreadTooWide", "InsufficientSources", "SequencerDown", "SequencerGracePeriod", "DegenerateBracket"}
SAFETY_CAUSES = ("physical inventory", "LP withdrawal reservation", "curator commitment limit", "vault flow limit",
                 "inventory concentration", "price-floor conflict", "oracle uncertainty or staleness")


def cause_of(e: Revert) -> str:
    """The brief's nine categories for an uninformed order that was not filled."""
    n = e.name
    if n == "QuotaExceeded":
        c = e.args_[0] if e.args_ else "full"
        return "curator commitment limit" if c == "full" else c
    if n == "FlowLimitExceeded":
        return "vault flow limit"
    if n in ("InventoryLimit", "ImpactBoundExceeded", "InventoryFloorBreached"):
        return "inventory concentration"
    if n == "PriceBelowFloor":
        return "price-floor conflict"
    if n in ORACLE_REASONS:
        return "oracle uncertainty or staleness"
    return "pricing-model limitation"  # ZeroOutput, AmountTooLarge, TradeImpactExceeded


class Sim:
    def __init__(self, world: World, cand: Candidate):
        self.w, self.c = world, cand
        self.p0 = _x96(world.mkt[0])
        if cand.kind == "X":
            self.eng = MultiEngine([HookAEngine(self.p0) if h == "hookA" else Engine(h, self.p0) for h in cand.hooks])
        else:
            self.eng = Engine(cand, self.p0)
        self.init = int(INIT * world.regime.scale)
        self.n0 = self.n1 = self.init * E18
        self.shares = self.init * E18  # sqrt(N0 * N1)
        self.q_cause = {True: "full", False: "full"}  # why the current allocation is below its target size
        self._ref_cache = (-1, None)
        self._excursion = None
        self.tau1 = self.n1 * WAD // self.shares
        self.pivot, self.pending_pivot = self.p0, None
        self.q = {True: 0, False: 0}  # remaining allocation by "vault sells currency1" (True) / currency0 (False)
        self.flow = {True: [0, -1], False: [0, -1]}
        self.queue = []  # (shares, slot requested)
        self.m = Metrics(days=world.regime.days)
        self.rng = random.Random(world.seed * 31 + zlib.crc32(cand.name.encode()))
        self._refresh(0)

    # --- vault helpers ---------------------------------------------------------------------------------------
    def snap(self) -> VaultSnapshot:
        return VaultSnapshot(self.n0, self.n1, self.shares)

    def _pending(self, n_a: int) -> int:
        p = sum(s for s, _ in self.queue)
        return 0 if p == 0 else -(-p * n_a // self.shares)

    def _refresh(self, k: int):
        for sells1 in (True, False):
            n_a = self.n1 if sells1 else self.n0
            target = int(ALLOC_FRACTION * self.init) * E18
            no_queue = max(0, int(n_a * (1 - BUFFER)))
            adm = max(0, no_queue - self._pending(n_a))
            self.q[sells1] = min(target, adm)
            self.q_cause[sells1] = ("full" if adm >= target else
                                    "LP withdrawal reservation" if no_queue >= target else "physical inventory")
        self._process_queue(k)

    def _process_queue(self, k: int):
        while self.queue:
            s, k0 = self.queue[0]
            a0 = s * self.n0 // self.shares
            a1 = s * self.n1 // self.shares
            if a0 > self.n0 - self.q[False] or a1 > self.n1 - self.q[True]:
                return
            self.n0, self.n1, self.shares = self.n0 - a0, self.n1 - a1, self.shares - s
            self.m.wd_wait_s += (k - k0) * SLOT * s / E18
            self.queue.pop(0)

    def reference(self, k: int) -> Reference | None:
        if not self.c.oracle or self.c.kind in ("A", "B"):
            return Reference(self.p0, 0)
        if self._ref_cache[0] == k:
            return self._ref_cache[1]
        r = self._reference_uncached(k)
        self._ref_cache = (k, r)
        return r

    def _set_ref_error(self, name: str):
        for e2 in getattr(self.eng, "engines", [self.eng]):
            e2._ref_error = name

    def _reference_uncached(self, k: int) -> Reference | None:
        mode = self.c.ref_mode
        if mode in ("bracket", "bracket_pull"):
            srcs = []
            has_payload = mode == "bracket_pull" and (
                self.c.fresh_avail >= 1.0 or (zlib.crc32(f"{self.w.seed}:{k}".encode()) % 10_000) < self.c.fresh_avail * 10_000)
            for name, feed in (("primary", self.w.vprim), ("secondary", self.w.vsec)) + (
                    (("pull", self.w.pull),) if has_payload else ()):
                p, u = feed[k]
                if p == 0 and name != "pull":
                    self._set_ref_error("ReferenceUnavailable")
                    return None
                if p:
                    srcs.append(BracketSource(p, u, *VERIFIED_BRACKET[name]))
            try:
                return bracket_reference(srcs, k * SLOT, min_sources=2)
            except Revert as e:
                self._set_ref_error(e.name)
                return None
        if mode == "point":
            p, u = self.w.vprim[k]
            q, qu = self.w.vsec[k]
            try:
                return resolve_reference(FeedReading(p, u), FeedReading(q, qu), k * SLOT,
                                         replace(POINT_POLICY, vol_mult=self.c.vol_mult), self.w.prim_hist(k, 5))
            except Revert as e:
                self._set_ref_error(e.name)
                return None
        if self.c.kind == "X":
            sub = [h for h in self.c.hooks if h != "hookA"]
            vm = sub[0].vol_mult if sub else 0
        else:
            vm = self.c.vol_mult
        return self._oracle_ref(k, vm)

    def _oracle_ref(self, k: int, vm: int) -> Reference | None:
        p, u = self.w.prim[k]
        s, su = self.w.sec[k]
        hist = self.w.prim_hist(k, 5)
        pol = replace(REF_POLICY, vol_mult=vm)
        try:
            return resolve_reference(FeedReading(p, u), FeedReading(s, su), k * SLOT, pol, hist)
        except Revert as e:
            for e2 in getattr(self.eng, "engines", [self.eng]):
                e2._ref_error = e.name
            return None

    def _vault_check(self, zfo: bool, amt: int, out: int, k: int):
        if self.c.floors in ("dynamic", "orb"):
            # The proposed vault-side dynamic floor: refuse any price inside the reference band (same adapter, same
            # block as the hook), on the vault's own rounding.
            ref = self.reference(k)
            if ref is None:
                raise Revert("ReferenceUnavailable")
            widen = PIPS + ref.uncertainty
            f_sell0 = mul_div_up(ref.price_x96, widen, PIPS)
            f_sell1 = mul_div_up(mul_div_up(Q96, Q96, ref.price_x96), widen, PIPS)
            if self.c.floors == "orb":
                if ref.uncertainty > self.c.max_unc:
                    raise Revert("UncertaintyTooHigh")
                held = self.n1 if zfo else self.n0
                floor_ = mul_div_up(self.shares * WAD, PIPS - self.c.kappa, WAD * PIPS)  # target 1 per share
                if held - out < floor_:
                    raise Revert("InventoryFloorBreached")
        else:
            f_sell0, f_sell1 = floors_from_pivot(self.pivot)
        if not floor_ok(amt, out, f_sell1 if zfo else f_sell0):
            raise Revert("PriceBelowFloor")
        if out > self.q[zfo]:
            raise Revert("QuotaExceeded", self.q_cause[zfo])
        day = (k * SLOT) // 86_400
        used = self.flow[zfo][0] if self.flow[zfo][1] == day else 0
        if used + out > int(FLOW_CAP * self.init) * E18:
            raise Revert("FlowLimitExceeded")

    def _apply(self, zfo: bool, amt: int, out: int, k: int):
        day = (k * SLOT) // 86_400
        used = self.flow[zfo][0] if self.flow[zfo][1] == day else 0
        self.flow[zfo] = [used + out, day]
        self.q[zfo] -= out
        if zfo:
            self.n0 += amt
            self.n1 -= out
        else:
            self.n1 += amt
            self.n0 -= out

    def try_trade(self, zfo: bool, amt: int, k: int, commit: bool = True):
        """Full path: hook quote, vault checks, state commit. Returns out or raises Revert."""
        ref = self.reference(k)
        out, tok = self.eng.quote(zfo, amt, k * SLOT, self.snap(), ref)
        if out == 0:
            raise Revert("ZeroOutput")
        self._vault_check(zfo, amt, out, k)
        if commit:
            self._apply(zfo, amt, out, k)
            self.eng.commit(tok, k * SLOT)
        return out

    # --- valuation ---------------------------------------------------------------------------------------------
    def _record_fill(self, zfo: bool, amt: int, out: int, k: int, who: str):
        mk = self.w.mkt[k]
        mf = self.w.mkt[min(k + MARKOUT // SLOT, len(self.w.mkt) - 1)]
        # value in currency0 tokens; one currency1 is worth 1 / mkt currency0
        if zfo:
            v_in, v_out, d1 = amt / E18, out / E18 / mk, -out / E18
        else:
            v_in, v_out, d1 = amt / E18 / mk, out / E18, amt / E18
        rev = v_in - v_out
        self.m.spread_rev += rev
        self.m.markout[who] += d1 * (1 / mf - 1 / mk)
        if who == "arb":
            self.m.arb_rev += rev
        self.m.fills += 1
        self.m.notional += v_in

    def _cost_bps(self, zfo: bool, amt: int, out: int, k: int) -> float:
        mk = self.w.mkt[k]
        v_in = amt / E18 if zfo else amt / E18 / mk
        v_out = out / E18 / mk if zfo else out / E18
        return (v_in - v_out) / v_in * 1e4

    def _inventory(self):
        t1 = self.shares * self.tau1 // WAD
        return (t1 - self.n1) / max(1, t1)

    # --- actors -----------------------------------------------------------------------------------------------
    def arbitrage(self, k: int):
        mk = self.w.mkt[k]
        for zfo in (True, False):
            def profit(a_tokens: float) -> float:
                amt = int(a_tokens * E18)
                if amt <= 0:
                    return 0.0
                try:
                    out = self.try_trade(zfo, amt, k, commit=False)
                except Revert:
                    return -1.0
                v_in = amt / E18 if zfo else amt / E18 / mk
                v_out = out / E18 / mk if zfo else out / E18
                return v_out - v_in * (1 + ARB_COST_BPS * 1e-4)

            probe = 50.0
            if profit(probe) <= 0:
                continue
            lo, hi = probe, probe
            while hi < 2e6 and profit(hi * 2) > profit(hi):
                lo, hi = hi, hi * 2
            hi *= 2
            # Golden-section search on the concave profit between lo and hi.
            g = (math.sqrt(5) - 1) / 2
            a, b = lo, hi
            for _ in range(22):
                c1, c2 = b - g * (b - a), a + g * (b - a)
                if profit(c1) >= profit(c2):
                    b = c2
                else:
                    a = c1
            best = a if profit(a) >= profit(lo) else lo
            if profit(best) <= 0:
                continue
            amt = int(best * E18)
            out = self.try_trade(zfo, amt, k)
            self._record_fill(zfo, amt, out, k, "arb")

    def order(self, o: Order, k: int):
        mk = self.w.mkt[k]
        amt_total = int((o.value if o.zfo else o.value * mk) * E18)
        dev = self._inventory()
        reduces = (dev > 0 and not o.zfo) or (dev < 0 and o.zfo)
        m = self.m
        if o.informed:
            m.informed += 1
        else:
            m.uninformed += 1
            m.reverse += reduces
        pieces = [amt_total // o.pieces] * o.pieces
        pieces[-1] += amt_total - sum(pieces)
        # Dry run all pieces (same block) on a copy-free basis: quote, check, apply, roll back on failure.
        saved = self._save()
        outs = []
        try:
            for p in pieces:
                outs.append(self.try_trade(o.zfo, p, k))
        except Revert as e:
            self._restore(saved)
            if self.c.kind == "D" and self._rfq(o, amt_total, k, reduces, 0):
                return
            _reason(m, e.name)
            if not o.informed:
                m.uninformed_refused += 1
                c = cause_of(e)
                m.causes[c] = m.causes.get(c, 0) + 1
            return
        out = sum(outs)
        if self.c.kind == "D":
            # A router takes the RFQ quote instead when it pays more; the on-chain fill is rolled back.
            self._restore(saved)
            if self._rfq(o, amt_total, k, reduces, out):
                return
            saved = self._save()
            for p in pieces:
                self.try_trade(o.zfo, p, k)
        cost = self._cost_bps(o.zfo, amt_total, out, k)
        if o.informed:
            mf = self.w.mkt[k + MARKOUT // SLOT]
            gain = (out / E18 / mf - amt_total / E18) if o.zfo else (out / E18 - amt_total / E18 / mf)
            accept = gain > 0
        else:
            accept = cost <= o.tol_bps
        if not accept:
            self._restore(saved)
            _reason(m, "TraderDeclined" if not o.informed else "InformedNoEdge")
            if not o.informed:
                m.causes["trader minimum-output constraint"] = m.causes.get("trader minimum-output constraint", 0) + 1
            return
        for p, q in zip(pieces, outs):
            self._record_fill(o.zfo, p, q, k, "informed" if o.informed else "uninformed")
        if o.informed:
            m.informed_filled += 1
        else:
            m.uninformed_filled += 1
            m.reverse_filled += reduces
            m.exec_cost_bps_sum += cost * (amt_total / E18)
            m.exec_value += amt_total / E18

    def _rfq(self, o: Order, amt: int, k: int, reduces: bool, onchain_out: int) -> bool:
        """D: an authorised maker quotes true market -/+ its spread; used only if it beats `onchain_out`. The vault
        still checks floor, quota and flow on the RFQ fill, exactly as on any other."""
        if self.rng.random() > self.c.rfq_avail:
            return False
        mk = self.w.mkt[k]
        h = self.c.rfq_spread / PIPS
        out = int(amt * mk * (1 - h)) if o.zfo else int(amt / mk * (1 - h))
        if out <= onchain_out:
            return False
        if self.c.rfq_inventory_checked:
            # The hook verifies the signed quote and applies the same inventory cap as its own quotes.
            ref = self.reference(k)
            if ref is None:
                return False
            i, v, t1 = inventory_state(self.c.c, self.snap())
            cap = min(straddle_cap(v, self.c.c.base_spread + ref.uncertainty, self.c.c.min_edge),
                      t1 * self.c.c.max_deviation // PIPS)
            i2 = i + out if o.zfo else i - amt
            if (o.zfo and i2 > cap) or (not o.zfo and i2 < -cap):
                return False
        try:
            self._vault_check(o.zfo, amt, out, k)
        except Revert:
            return False
        cost = self._cost_bps(o.zfo, amt, out, k)
        if not o.informed and cost > o.tol_bps:
            return False
        if o.informed:
            mf = self.w.mkt[k + MARKOUT // SLOT]
            if ((out / E18 / mf - amt / E18) if o.zfo else (out / E18 - amt / E18 / mf)) <= 0:
                return False
        self._apply(o.zfo, amt, out, k)
        self._record_fill(o.zfo, amt, out, k, "rfq")
        self.m.rfq_fills += 1
        if o.informed:
            self.m.informed_filled += 1
        else:
            self.m.uninformed_filled += 1
            self.m.reverse_filled += reduces
            self.m.exec_cost_bps_sum += cost * (amt / E18)
            self.m.exec_value += amt / E18
        return True

    def withdraw(self, frac: float, k: int):
        s = int(self.shares * frac)
        if s == 0:
            return
        self.m.wd_requested += s / E18
        a0 = s * self.n0 // self.shares
        a1 = s * self.n1 // self.shares
        if not self.queue and a0 <= self.n0 - self.q[False] and a1 <= self.n1 - self.q[True]:
            self.n0, self.n1, self.shares = self.n0 - a0, self.n1 - a1, self.shares - s
            self.m.wd_instant += s / E18
        else:
            self.queue.append((s, k))

    def _save(self):
        return (self.n0, self.n1, dict(self.q), {d: list(v) for d, v in self.flow.items()}, self.eng.save())

    def _restore(self, s):
        self.n0, self.n1, self.q, self.flow = s[0], s[1], dict(s[2]), {d: list(v) for d, v in s[3].items()}
        self.eng.restore(s[4])

    def keeper(self, k: int):
        if self.c.floors != "keeper":
            return
        if self.pending_pivot and k >= self.pending_pivot[1]:
            self.pivot, self.pending_pivot = self.pending_pivot[0], None
            if self.c.kind in ("A", "B", "X"):  # the same keeper transaction re-prices the hooks
                self.eng.reprice(self.pivot, k * SLOT)
        p, _ = (self.w.vprim if self.c.ref_mode == "point" else self.w.prim)[k]
        if p and self.pending_pivot is None and abs(p / self.pivot - 1) > self.c.keeper_band:
            self.pending_pivot = (p, k + max(1, self.c.keeper_delay // SLOT))

    # --- run --------------------------------------------------------------------------------------------------
    def run(self) -> Metrics:
        w, m = self.w, self.m
        m.value0 = 2 * self.init
        m.init = float(self.init)
        wd = list(w.withdrawals)
        next_refresh = REFRESH // SLOT
        last_k = 0
        for o in w.orders:
            k = o.slot
            while next_refresh <= k:
                self.keeper(next_refresh)
                self._refresh(next_refresh)
                next_refresh += REFRESH // SLOT
            while wd and wd[0][0] <= k:
                kk, f = wd.pop(0)
                self.withdraw(f, kk)
            self.keeper(k)
            self.arbitrage(k)
            self.order(o, k)
            dev = abs(self._inventory())
            if dev > 0.10 and self._excursion is None:
                self._excursion = k
            elif dev < 0.05 and self._excursion is not None:
                m.recoveries.append((k - self._excursion) * SLOT)
                self._excursion = None
            m.dev_sum += dev
            m.dev_n += 1
            m.dev_max = max(m.dev_max, dev)
            mk = w.mkt[k]
            v0, v1 = self.n0 / E18, self.n1 / E18 / mk
            m.conc_max = max(m.conc_max, abs(v1 / (v0 + v1) - 0.5))
            last_k = k
        mk = w.mkt[last_k]
        per_share = (self.n0 / E18 + self.n1 / E18 / mk) / (self.shares / E18)
        hodl = (self.init + self.init / mk) / self.init
        m.lp_pnl_bps = (per_share / hodl - 1) * 1e4
        m.final_dev = self._inventory()
        for s, k0 in self.queue:
            m.wd_wait_s += (last_k - k0) * SLOT * s / E18
        return m


def run_one(args):
    reg, seed, cand = args
    w = build_world(reg, seed)
    return reg.name, seed, cand.name, asdict(Sim(w, cand).run())


# ------------------------------------------------------------------------------------------------------------------
# Reporting
# ------------------------------------------------------------------------------------------------------------------


def _sum_causes(ms: list[dict]) -> dict:
    out: dict = {}
    for x in ms:
        for k, v in x.get("causes", {}).items():
            out[k] = out.get(k, 0) + v
    return out


def summarise(ms: list[dict]) -> dict:
    tot = lambda k: sum(x[k] for x in ms)  # noqa: E731
    reasons: dict = {}
    for x in ms:
        for r, c in x["reasons"].items():
            reasons[r] = reasons.get(r, 0) + c
    pnl = [x["lp_pnl_bps"] for x in ms]
    days = tot("days")
    return {
        "fill%": 100 * tot("uninformed_filled") / max(1, tot("uninformed")),
        "protocol accept%": 100 * (1 - tot("uninformed_refused") / max(1, tot("uninformed"))),
        "reverse fill%": 100 * tot("reverse_filled") / max(1, tot("reverse")),
        "informed fill%": 100 * tot("informed_filled") / max(1, tot("informed")),
        "exec cost bps": tot("exec_cost_bps_sum") / max(1e-9, tot("exec_value")),
        "LP vs HODL bps (median)": statistics.median(pnl),
        "LP vs HODL bps (worst)": min(pnl),
        "spread rev/day": tot("spread_rev") / days,
        "arb rev/day": tot("arb_rev") / days,
        "markout unin/day": sum(x["markout"]["uninformed"] for x in ms) / days,
        "markout inf/day": sum(x["markout"]["informed"] for x in ms) / days,
        "mean |dev|%": 100 * tot("dev_sum") / max(1, tot("dev_n")),
        "max |dev|%": 100 * max(x["dev_max"] for x in ms),
        "max conc%": 100 * max(x["conc_max"] for x in ms),
        "turnover/day": sum(x["notional"] / x["days"] / (2 * x["init"]) for x in ms) / len(ms),
        "wd instant%": 100 * tot("wd_instant") / tot("wd_requested") if tot("wd_requested") else None,
        "rfq fills": tot("rfq_fills"),
        "reasons": reasons,
        "causes": _sum_causes(ms),
        "fill% | quotable": 100 * tot("uninformed_filled") / max(1, tot("uninformed_filled") + _sum_causes(ms).get(
            "trader minimum-output constraint", 0)),
        "fill% | safe demand": 100 * tot("uninformed_filled") / max(1, tot("uninformed") - sum(
            _sum_causes(ms).get(c, 0) for c in SAFETY_CAUSES)),
    }


COLS = ["fill%", "protocol accept%", "reverse fill%", "exec cost bps", "LP vs HODL bps (median)", "LP vs HODL bps (worst)",
        "spread rev/day", "arb rev/day", "markout inf/day", "mean |dev|%", "max |dev|%", "turnover/day", "wd instant%"]


def fmt(v):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:,.2f}"
    return str(v)


def run_grid(regimes, seeds, cands, workers=None):
    jobs = [(r, s, c) for r in regimes for s in seeds for c in cands]
    with ProcessPoolExecutor(max_workers=workers) as ex:
        res = list(ex.map(run_one, jobs, chunksize=1))
    table: dict = {}
    for rn, s, cn, m in res:
        table.setdefault((rn, cn), []).append(m)
    return table


def print_table(table, regimes, cands, title):
    print(f"\n### {title}\n")
    print("| regime | candidate | " + " | ".join(COLS) + " | refusals |")
    print("|---" * (len(COLS) + 3) + "|")
    for r in regimes:
        for c in cands:
            s = summarise(table[(r.name, c.name)])
            top = dict(sorted(s["reasons"].items(), key=lambda kv: -kv[1])[:4])
            print(f"| {r.name} | {c.name} | " + " | ".join(fmt(s[k]) for k in COLS) + f" | {top} |")


def overall(table, regimes, cands, title):
    print(f"\n### {title}: across regimes (median and worst regime)\n")
    print("| candidate | fill% median | fill% worst | reverse fill% median | LP vs HODL bps median regime | "
          "LP vs HODL bps worst regime | worst single world | arb rev/day median | max |dev|% worst |")
    print("|---" * 10 + "|")
    out = {}
    for c in cands:
        per = [summarise(table[(r.name, c.name)]) for r in regimes]
        worlds = [x["lp_pnl_bps"] for r in regimes for x in table[(r.name, c.name)]]
        row = {
            "fill_med": statistics.median(p["fill%"] for p in per),
            "fill_worst": min(p["fill%"] for p in per),
            "rev_med": statistics.median(p["reverse fill%"] for p in per),
            "pnl_med": statistics.median(p["LP vs HODL bps (median)"] for p in per),
            "pnl_worst": min(p["LP vs HODL bps (median)"] for p in per),
            "pnl_world_worst": min(worlds),
            "arb_med": statistics.median(p["arb rev/day"] for p in per),
            "dev_worst": max(p["max |dev|%"] for p in per),
        }
        out[c.name] = row
        print(f"| {c.name} | " + " | ".join(fmt(v) for v in row.values()) + " |")
    return out


def calibrate():
    """Parameter grids on the CALIBRATION seeds only, one per family (A, B, C), so that every candidate is compared at
    its own best setting. Selection rule, fixed before running: maximise the worst regime's median LP-vs-HODL (rounded
    to 1 bp), then the median regime's. Fill rate and revenue are reported, not optimised."""
    print("SYNTHETIC calibration worlds, seeds", CALIBRATION_SEEDS, "- not historical data.")
    keeper = dict(oracle=True, floors="keeper")
    families = {
        "A": [Candidate(f"A depth={d / 1e6:g}M", "A", a_depth=d, **keeper) for d in (500_000, 1_000_000, 2_000_000)],
        "B": [Candidate(f"B h={h / 100:g}bps cap={m / 1e4:g}%", "B", b_spread=h, b_impact=m, **keeper)
              for h in (1_000, 2_000, 3_000, 5_000) for m in (h, 20_000)],
        "C": [Candidate(f"C h={h / 100:g}bps dev={d / 1e4:g}% vol={vm}%", "C", c=c_config(h, d), vol_mult=vm, **keeper)
              for h in (500, 1_000, 2_000, 3_000, 5_000) for d in (50_000, 150_000, 300_000) for vm in (0, 25, 50, 100)],
    }
    selected, out = {}, {}
    for fam, grid in families.items():
        table = run_grid(REGIMES, CALIBRATION_SEEDS, grid)
        ov = overall(table, REGIMES, grid, f"Calibration grid, family {fam} (calibration seeds)")
        ranked = sorted(ov.items(), key=lambda kv: (round(kv[1]["pnl_worst"]), kv[1]["pnl_med"]), reverse=True)
        selected[fam] = ranked[0][0]
        out[fam] = ov
        print(f"\nSelected for {fam} (worst-regime LP vs HODL, then median):", ranked[0][0])
    os.makedirs(os.path.join(os.path.dirname(__file__), "results"), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "results", "calibration.json"), "w") as f:
        json.dump({"selected": selected, "rule": "max worst-regime median LP vs HODL (1 bp), then median regime",
                   "seeds": CALIBRATION_SEEDS, "grids": out}, f, indent=1, sort_keys=True)
    return selected


# ------------------------------------------------------------------------------------------------------------------
# Phase 1B-4.1: verified references, the vault-side dynamic floor, both strategies, rejection attribution
# ------------------------------------------------------------------------------------------------------------------

CAUSE_ORDER = ["physical inventory", "LP withdrawal reservation", "curator commitment limit", "vault flow limit",
               "inventory concentration", "price-floor conflict", "oracle uncertainty or staleness",
               "trader minimum-output constraint", "pricing-model limitation"]


def _families_141():
    keeper = dict(oracle=True, floors="keeper")
    dyn = dict(oracle=True, floors="dynamic")
    fam = {
        "point": [Candidate(f"point h={h / 100:g} vol={vm}", "C", ref_mode="point", c=c_config(h, 150_000),
                            vol_mult=vm, **keeper) for h in (500, 1_000, 2_000, 4_000) for vm in (0, 50)],
        "bracket": [Candidate(f"bracket h={h / 100:g} vol={vm}", "C", ref_mode="bracket",
                              c=c_config(h, 150_000, max_spread=40_000, band=True), vol_mult=vm, **dyn)
                    for h in (200, 500, 1_000, 2_000) for vm in (0,)],
        "bracket_pull": [Candidate(f"bracket+pull h={h / 100:g}", "C", ref_mode="bracket_pull",
                                   c=c_config(h, 150_000, max_spread=40_000, band=True), **dyn)
                         for h in (200, 500, 1_000, 2_000)],
    }
    return fam


def phase141(workers=None):
    """Calibrate each reference mode on calibration seeds (same pre-declared rule as Phase 1B-4), then evaluate the
    selections on held-out seeds with rejection attribution. SYNTHETIC; feed parameters as verified on Unichain."""
    print("Phase 1B-4.1. SYNTHETIC worlds. Calibration seeds", CALIBRATION_SEEDS, "held-out", HELD_OUT_SEEDS)
    selected = {}
    for fam, grid in _families_141().items():
        table = run_grid(REGIMES_141, CALIBRATION_SEEDS, grid, workers)
        ov = overall(table, REGIMES_141, grid, f"Calibration, {fam}")
        ranked = sorted(ov.items(), key=lambda kv: (round(kv[1]["pnl_worst"]), kv[1]["pnl_med"]), reverse=True)
        selected[fam] = next(c for c in grid if c.name == ranked[0][0])
        print(f"\nSelected for {fam}:", ranked[0][0])
    p0 = next(c for c in CANDIDATES if c.name.startswith("C3"))
    p2 = selected["bracket"]
    cands = [
        replace(p0, name="P0 C3, assumed feeds (Phase 1B-4)"),
        replace(selected["point"], name=f"P1 verified feeds, point mid ({selected['point'].name})"),
        replace(p2, name=f"P2 verified bracket + vault dynamic floor ({p2.name})"),
        replace(selected["bracket_pull"], name=f"P3 bracket + hypothetical pull ({selected['bracket_pull'].name})"),
        Candidate("P4 Hook A + Hook B strategies on P2's shared core", "X", ref_mode="bracket", oracle=True,
                  floors="dynamic", hooks=(replace(p2, strategy="A"), replace(p2, strategy="B"))),
    ]
    table = run_grid(REGIMES_141, HELD_OUT_SEEDS, cands, workers)
    ov = overall(table, REGIMES_141, cands, "Held-out, Phase 1B-4.1 candidates")
    stress = run_grid(STRESS, HELD_OUT_SEEDS, cands, workers)
    print("\n### Rejection attribution, held-out (share of uninformed orders, %)\n")
    print("| regime | candidate | fill% | fill% given quotable | fill% given safe demand | " + " | ".join(CAUSE_ORDER)
          + " |")
    print("|---" * (len(CAUSE_ORDER) + 5) + "|")
    rows = {}
    for src, regs in ((table, REGIMES_141), (stress, STRESS)):
        for r in regs:
            for c in cands:
                sm = summarise(src[(r.name, c.name)])
                n = sum(x["uninformed"] for x in src[(r.name, c.name)])
                shares = [100 * sm["causes"].get(k, 0) / max(1, n) for k in CAUSE_ORDER]
                rows[f"{r.name} | {c.name}"] = {**{k: sm[k] for k in ("fill%", "fill% | quotable", "fill% | safe demand",
                                                                       "LP vs HODL bps (median)",
                                                                       "LP vs HODL bps (worst)", "arb rev/day",
                                                                       "exec cost bps", "max |dev|%")},
                                                "causes%": dict(zip(CAUSE_ORDER, shares))}
                print(f"| {r.name} | {c.name[:3]} | {sm['fill%']:.1f} | {sm['fill% | quotable']:.1f} | "
                      f"{sm['fill% | safe demand']:.1f} | " + " | ".join(f"{x:.1f}" for x in shares) + " |")
    print("\n### Economics, held-out and stress (median LP vs HODL bps / worst seed / arbitrage per day / cost bps)\n")
    for k, v in rows.items():
        print(f"- {k}: {v['LP vs HODL bps (median)']:.1f} / {v['LP vs HODL bps (worst)']:.1f} / "
              f"{v['arb rev/day']:.1f} / {v['exec cost bps']:.1f}; max dev {v['max |dev|%']:.1f}%")
    os.makedirs(os.path.join(os.path.dirname(__file__), "results"), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "results", "phase141_summary.json"), "w") as f:
        json.dump({"selected": {k: v.name for k, v in selected.items()}, "overall": ov, "rows": rows},
                  f, indent=1, sort_keys=True)


# ------------------------------------------------------------------------------------------------------------------
# Phase 1B-4.2: the oracle risk boundary in the vault, correlated oracle failures, fresh-source availability
# ------------------------------------------------------------------------------------------------------------------

ATTACKS = [
    Regime("A1 one source +1.5% for 6 h (inside the detection band)", days=3, manip_primary=((0.4, 6 * 3600, math.log(1.015)),)),
    Regime("A2 one source +3% for 30 min (detected)", days=3, manip_primary=((0.5, 1800, math.log(1.03)),)),
    Regime("A3 both sources +5% for 6 h (shared upstream)", days=3,
           manip_primary=((0.4, 6 * 3600, math.log(1.05)),), manip_secondary=((0.4, 6 * 3600, math.log(1.05)),)),
    Regime("A4 malicious adapter: price halved for 1 day", days=3,
           manip_primary=((0.3, 86_400, math.log(0.5)),), manip_secondary=((0.3, 86_400, math.log(0.5)),)),
    Regime("A5 both feeds frozen through a -10% move over 2 h", days=3, vol_day=0.02, freeze=((0.4, 3 * 3600),),
           jumps=tuple((0.4 + i * 0.0001, math.log(0.9) / 70) for i in range(70))),
    Regime("A6 sudden -8% jump", days=3, vol_day=0.02, jumps=((0.5, math.log(0.92)),)),
    Regime("A7 depeg -15% in 1 h then drift", days=3, vol_day=0.03, drift_day=-0.03,
           jumps=tuple((0.3 + i * 0.0005, math.log(0.85) / 30) for i in range(30))),
]


def _cands_142():
    dyn = dict(oracle=True, floors="dynamic")
    orb = dict(oracle=True, floors="orb")
    b10 = c_config(1_000, 150_000, max_spread=40_000, band=True)
    b20 = c_config(2_000, 150_000, max_spread=40_000, band=True)
    return [
        Candidate("Q0 push bracket, dynamic floor only (Phase 1B-4.1)", "C", ref_mode="bracket", c=b10, **dyn),
        Candidate("Q1 push bracket + oracle risk boundary (kappa 15%)", "C", ref_mode="bracket", c=b10, **orb),
        Candidate("Q2 push + fresh credentialed source (95% availability) + boundary", "C", ref_mode="bracket_pull",
                  c=b20, fresh_avail=0.95, **orb),
        Candidate("Q3 as Q2, kappa 5%", "C", ref_mode="bracket_pull", c=c_config(2_000, 50_000, max_spread=40_000,
                                                                                 band=True), fresh_avail=0.95,
                  kappa=50_000, **orb),
    ]


def phase142(workers=None):
    print("Phase 1B-4.2. SYNTHETIC worlds; held-out seeds", HELD_OUT_SEEDS)
    cands = _cands_142()
    table = run_grid(REGIMES_141, HELD_OUT_SEEDS, cands, workers)
    ov = overall(table, REGIMES_141, cands, "Held-out, Phase 1B-4.2 candidates")
    att = run_grid(ATTACKS, HELD_OUT_SEEDS, cands, workers)
    rows = {}
    print("\n### Attacks (3-day worlds, 4 seeds): LP vs HODL bps median / worst seed; arbitrage revenue per day; "
          "refusal causes (% of uninformed)\n")
    print("| attack | candidate | LP median | LP worst | arb/day | max dev% | oracle refusals | inventory refusals |")
    print("|---|---|---|---|---|---|---|---|")
    for r in ATTACKS:
        for c in cands:
            ms = att[(r.name, c.name)]
            sm = summarise(ms)
            n = max(1, sum(x["uninformed"] for x in ms))
            ora = 100 * sm["causes"].get("oracle uncertainty or staleness", 0) / n
            inv = 100 * sm["causes"].get("inventory concentration", 0) / n
            rows[f"{r.name} | {c.name}"] = {"lp_med": sm["LP vs HODL bps (median)"],
                                            "lp_worst": sm["LP vs HODL bps (worst)"], "arb": sm["arb rev/day"],
                                            "max_dev": sm["max |dev|%"], "oracle%": ora, "inventory%": inv}
            print(f"| {r.name} | {c.name[:2]} | {sm['LP vs HODL bps (median)']:.1f} | "
                  f"{sm['LP vs HODL bps (worst)']:.1f} | {sm['arb rev/day']:.1f} | {sm['max |dev|%']:.1f} | "
                  f"{ora:.1f} | {inv:.1f} |")
    print("\n### Inventory recovery (held-out; seconds from |deviation| > 10% back to < 5%)\n")
    rec = {}
    for c in cands:
        allr = [t for r in REGIMES_141 for x in table[(r.name, c.name)] for t in x["recoveries"]]
        rec[c.name] = {"episodes": len(allr), "median_s": statistics.median(allr) if allr else None,
                       "max_s": max(allr) if allr else None}
        print(f"- {c.name}: {rec[c.name]}")
    # Strategy differentiation: Hook A (activity fee 0 -> 20 bps) beside Hook B with a flat 10 bp markup, on Q2's core.
    q2 = cands[2]
    diff = [replace(q2, name="S0 Hook B alone (no markup)"),
            Candidate("S1 Hook A (0->20 bps activity fee) + Hook B (10 bp markup)", "X", ref_mode="bracket_pull",
                      oracle=True, floors="orb", fresh_avail=0.95,
                      hooks=(replace(q2, strategy="A"), replace(q2, b_markup=1_000)))]
    dt = run_grid(REGIMES_141, HELD_OUT_SEEDS, diff, workers)
    dov = overall(dt, REGIMES_141, diff, "Strategy differentiation (held-out)")
    os.makedirs(os.path.join(os.path.dirname(__file__), "results"), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "results", "phase142_summary.json"), "w") as f:
        json.dump({"overall": ov, "attacks": rows, "recovery": rec, "differentiation": dov,
                   "regimes": {f"{r} | {c}": {k: v for k, v in summarise(x).items() if k != "reasons"}
                               for (r, c), x in table.items()}}, f, indent=1, sort_keys=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--calibrate", action="store_true")
    ap.add_argument("--quick", action="store_true", help="2 seeds, for development only")
    ap.add_argument("--workers", type=int, default=None)
    ap.add_argument("--phase141", action="store_true", help="Phase 1B-4.1 experiment (verified feeds)")
    ap.add_argument("--phase142", action="store_true", help="Phase 1B-4.2 experiment (oracle risk boundary)")
    a = ap.parse_args()
    if a.phase142:
        phase142(a.workers)
        return
    if a.phase141:
        phase141(a.workers)
        return
    if a.calibrate:
        calibrate()
        return
    seeds = HELD_OUT_SEEDS[:2] if a.quick else HELD_OUT_SEEDS
    print("SYNTHETIC worlds, held-out seeds", seeds, "- not historical data.")
    table = run_grid(REGIMES, seeds, CANDIDATES, a.workers)
    print_table(table, REGIMES, CANDIDATES, "Held-out worlds, per regime")
    ov = overall(table, REGIMES, CANDIDATES, "Held-out worlds")
    st = run_grid(STRESS, seeds, CANDIDATES, a.workers)
    print_table(st, STRESS, CANDIDATES, "Stress worlds (held-out seeds)")
    xt = run_grid(REGIMES, seeds, CROSS, a.workers)
    print_table(xt, REGIMES, CROSS, "Two hooks on one reserve (held-out seeds)")
    xo = overall(xt, REGIMES, CROSS, "Two hooks on one reserve")
    os.makedirs(os.path.join(os.path.dirname(__file__), "results"), exist_ok=True)
    with open(os.path.join(os.path.dirname(__file__), "results", "heldout_summary.json"), "w") as f:
        json.dump({"overall": ov,
                   "regimes": {f"{r} | {c}": summarise(v) for (r, c), v in table.items()},
                   "stress": {f"{r} | {c}": summarise(v) for (r, c), v in st.items()},
                   "cross_hook": {"overall": xo, "regimes": {f"{r} | {c}": summarise(v) for (r, c), v in xt.items()}}},
                  f, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
