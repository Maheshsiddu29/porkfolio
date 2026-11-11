"""Integer reference model of the market-making candidates studied in Phase 1B-4.

Every quote function here is written as the Solidity would compute it: unbounded Python integers, explicit floor or
ceiling on every division, no floats. Floats appear only in `simulate.py`, for the synthetic market and for valuing
results, never inside a quote.

The arithmetic of the existing Hook B curve (`positionCost`, `positionForCost`, `maxPosition`) is imported from
`simulations/pricing/cumulative.py`, which is differential-tested against the production Solidity
(`test/unit/CumulativePricing.t.sol`). Candidate C reuses those exact functions inside its cap.

Units
-----
- Raw token units everywhere. `price_x96` = raw currency1 per raw currency0, Q64.96, as in the hooks.
- Spreads, edges and caps in pips: 1,000,000 pips = 100%.
- Per-share quantities are WAD (1e18) scaled: raw units per share * 1e18.
- The vault's "inventory deviation" I is in raw currency1: target currency1 minus net currency1 held. I > 0 means the
  vault has sold currency1 relative to its target (the same sign as Hook B's position x).

Candidates
----------
A  `HookBLegacy`        the production Hook B (Phase 1B-3): decaying signed position, static P, zero spread.
B  `TwoSidedCurve`      Hook B's curve and decaying position plus an explicit half-spread on each side.
C  `quote_inventory`    the vault's real inventory as the pricing state, an external reference mid, an uncertainty
                        spread, and a cap chosen so that every quote straddles the reference (bid <= mid <= ask).
D  hybrid               C plus an authorised RFQ fallback. It is not a pricing function and lives in `simulate.py`.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from math import isqrt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "pricing"))

from cumulative import (  # noqa: E402
    MAX_AMOUNT,
    PIPS,
    Q96,
    HookA,
    HookAConfig,
    HookB,
    HookBConfig,
    Revert,
    decayed_signed,
    floor_ok,
    max_position,
    mul_div,
    mul_div_up,
    position_cost,
    position_for_cost,
)

WAD = 10**18

__all__ = [
    "PIPS", "Q96", "WAD", "MAX_AMOUNT", "Revert", "HookA", "HookAConfig", "HookB", "HookBConfig", "floor_ok", "mul_div", "mul_div_up",
    "position_cost", "position_for_cost", "max_position", "decayed_signed",
    "VaultSnapshot", "FeedReading", "ReferencePolicy", "Reference", "resolve_reference", "realized_vol_term",
    "TwoSidedCurveConfig", "TwoSidedCurve", "InventoryConfig", "InventoryQuote", "inventory_state",
    "straddle_cap", "depth_per_share_for", "ext_cost", "ext_position_for_cost", "quote_inventory", "floors_from_pivot",
]


# ----------------------------------------------------------------------------------------------------------------
# Spread helpers. Both round in the vault's favour and are applied once per trade.
# ----------------------------------------------------------------------------------------------------------------


def credit_in(amount_in: int, half_spread: int) -> int:
    """Potential units an exact input buys after paying `half_spread`: floor(in * PIPS / (PIPS + h)).

    The trader pays (1 + h) per unit of potential. Floor: the trader is credited at most the exact value, so a split
    into n pieces is credited at most what one trade is (sum of floors <= floor of sum)."""
    return amount_in * PIPS // (PIPS + half_spread)


def debit_out(gross: int, half_spread: int) -> int:
    """Output after the vault keeps `half_spread`: floor(gross * (PIPS - h) / PIPS)."""
    return gross * (PIPS - half_spread) // PIPS


# ----------------------------------------------------------------------------------------------------------------
# Vault floors (SharedCommitmentVault.setSellFloor, exchange)
# ----------------------------------------------------------------------------------------------------------------


def floors_from_pivot(pivot_x96: int) -> tuple[int, int]:
    """Loosest D14-consistent floor pair around a pivot price K (raw currency1 per raw currency0, Q96).

    Returns (F_sell0, F_sell1) as the vault stores them: F_sell0 is raw currency1 in per raw currency0 out (= K),
    F_sell1 is raw currency0 in per raw currency1 out (= ceil(2^192 / K)). Their product is >= 2^192 (the D14 rule)
    and no pair whose product is >= 2^192 lets the vault both sell currency1 below K and buy it above K: D14 floors
    can only be a single pivot or a no-trade gap, never a band that contains the market on both sides."""
    return pivot_x96, mul_div_up(Q96, Q96, pivot_x96)


# ----------------------------------------------------------------------------------------------------------------
# Reference price
# ----------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class FeedReading:
    """One price source as a contract would read it: last answer and its timestamp. `price_x96 == 0` = no answer."""

    price_x96: int
    updated_at: int


@dataclass(frozen=True)
class ReferencePolicy:
    """How the hook turns one or two feed readings into a mid and an uncertainty, or refuses.

    max_age:              primary older than this (seconds) -> StaleReference.
    max_divergence:       |primary - secondary| above this (pips of the lower) -> ReferenceDivergence.
    secondary_max_age:    a secondary older than this is treated as missing.
    require_secondary:    if True a missing secondary -> SecondaryUnavailable; if False it adds `missing_penalty`.
    missing_penalty:      pips added to the uncertainty when the secondary is missing and not required.
    age_widen:            pips added at age == max_age, linearly from 0 at age 0 (rounded up).
    vol_mult:             percent multiplier on the realized-volatility term (0 disables it).
    vol_horizon:          seconds over which the volatility term is projected.
    """

    max_age: int
    max_divergence: int
    secondary_max_age: int
    require_secondary: bool = False
    missing_penalty: int = 0
    age_widen: int = 0
    vol_mult: int = 0
    vol_horizon: int = 300


@dataclass(frozen=True)
class Reference:
    price_x96: int  # mid, raw currency1 per raw currency0, Q96
    uncertainty: int  # pips added to both half-spreads


def realized_vol_term(history: list[FeedReading], horizon: int, mult: int) -> int:
    """Volatility widening from the primary feed's own recent rounds, with no hook storage.

    For consecutive rounds i-1, i: r_i = |p_i - p_{i-1}| * PIPS / min(p_i, p_{i-1}) (pips, rounded up) and
    dt_i = t_i - t_{i-1} (seconds, at least 1). The per-second variance estimate is mean(r_i^2 / dt_i) (rounded up);
    the term is ceil(mult / 100 * sqrt(variance * horizon)) pips. A push feed updates on deviation, so its rounds
    sample the path at its threshold: in a calm market rounds are far apart (small r^2/dt), in a fast market close
    together (large). Example: rounds 0.2% apart every 60 s give r = 2,000 pips, variance 66,667 pips^2/s, and over a
    300 s horizon sqrt(2 * 10^7) = 4,473 pips at mult = 100. A contract reads the history with the feed's round-data
    getter; it is a bounded number of view calls, not new state."""
    if mult == 0 or len(history) < 2:
        return 0
    acc, n = 0, 0
    for a, b in zip(history, history[1:]):
        lo, hi = sorted((a.price_x96, b.price_x96))
        r = mul_div_up(hi - lo, PIPS, lo)
        acc += -(-r * r // max(1, b.updated_at - a.updated_at))
        n += 1
    var = -(-acc // n)
    return -(-isqrt(var * horizon) * mult // 100)


def resolve_reference(primary: FeedReading, secondary: FeedReading | None, now: int, pol: ReferencePolicy,
                      history: list[FeedReading] | None = None) -> Reference:
    """Fail-closed reference: never invents a price. Uncertainty = divergence + age widening + realized-volatility
    widening (+ missing-secondary penalty). `history` is the primary's recent rounds, oldest first."""
    if primary.price_x96 == 0 or primary.updated_at > now:
        raise Revert("ReferenceUnavailable")
    age = now - primary.updated_at
    if age > pol.max_age:
        raise Revert("StaleReference", age)
    unc = mul_div_up(pol.age_widen, age, pol.max_age) if pol.age_widen else 0
    sec_ok = secondary is not None and secondary.price_x96 != 0 and now - secondary.updated_at <= pol.secondary_max_age
    if sec_ok:
        lo, hi = sorted((primary.price_x96, secondary.price_x96))
        div = mul_div_up(hi - lo, PIPS, lo)
        if div > pol.max_divergence:
            raise Revert("ReferenceDivergence", div)
        unc += div
    elif pol.require_secondary:
        raise Revert("SecondaryUnavailable")
    else:
        unc += pol.missing_penalty
    if history:
        unc += realized_vol_term(history, pol.vol_horizon, pol.vol_mult)
    return Reference(primary.price_x96, unc)


# ----------------------------------------------------------------------------------------------------------------
# Candidate B: Hook B's decaying signed position on a static P, plus a half-spread on each side
# ----------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TwoSidedCurveConfig:
    price_x96: int
    depth: int  # V, raw currency1
    max_impact: int  # pips, cap on the curve's marginal premium (as Hook B)
    window: int  # decay window, seconds (0 = none)
    half_spread: int  # pips, charged on each side

    @property
    def xmax(self) -> int:
        return max_position(self.depth, self.max_impact)


class TwoSidedCurve:
    """Hook B with bid != ask. Vault sells currency1 at (1 + h) times the curve, buys it at (1 - h) times the curve.

    A round trip that returns x to its start costs the trader 2h of the curve segment (plus remainders); same-direction
    splits telescope exactly as in Hook B, and each per-trade spread rounding favours the vault."""

    def __init__(self, cfg: TwoSidedCurveConfig):
        self.cfg = cfg
        self.x = 0
        self.updated = 0

    def position_now(self, now: int) -> int:
        return decayed_signed(self.x, self.cfg.xmax, self.cfg.window, now - self.updated)

    def quote(self, zero_for_one: bool, amount_in: int, now: int) -> tuple[int, int]:
        c = self.cfg
        V, P, cap, h = c.depth, c.price_x96, c.xmax, c.half_spread
        x = self.position_now(now)
        if zero_for_one:
            t = position_cost(x, V, P) + credit_in(amount_in, h)
            if t >= position_cost(cap + 1, V, P):
                raise Revert("ImpactBoundExceeded", x, cap)
            x2 = position_for_cost(t, V, P)
            return x2 - x, x2
        x2 = x - amount_in
        if x2 < -cap:
            raise Revert("ImpactBoundExceeded", x, cap)
        return debit_out(position_cost(x, V, P) - position_cost(x2, V, P), h), x2

    def commit(self, x2: int, now: int) -> None:
        self.x, self.updated = x2, now


# ----------------------------------------------------------------------------------------------------------------
# Candidate C: real-inventory potential around an external reference, with an uncertainty spread
# ----------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class VaultSnapshot:
    """What the hook reads from the vault: N_0, N_1 (net assets = backing - claimable) and total shares S."""

    n0: int
    n1: int
    shares: int


@dataclass(frozen=True)
class InventoryConfig:
    """Parameters of candidate C. All set by governance; none is derived from trader input.

    target_per_share: tau, target currency1 per share (WAD). T_1 = floor(S * tau / WAD).
    depth_per_share:  depth per share (WAD). V = min(depth_max, floor(S * depth_per_share / WAD)).
    depth_max:        absolute cap on V, raw currency1 (bounds what a just-in-time deposit can deepen).
    base_spread:      half-spread before uncertainty, pips.
    min_edge:         h_min: every quote stays at least this far on the vault's side of the reference, pips.
    max_spread:       refuse to quote when base + uncertainty exceeds this, pips.
    max_deviation:    risk cap on |I| in pips of T_1 (applied together with the straddle cap).
    """

    target_per_share: int
    depth_per_share: int
    depth_max: int
    base_spread: int
    min_edge: int
    max_spread: int
    max_deviation: int


@dataclass(frozen=True)
class InventoryQuote:
    amount_out: int
    i_before: int
    i_after: int
    half_spread: int
    cap: int
    depth: int


def inventory_state(cfg: InventoryConfig, snap: VaultSnapshot) -> tuple[int, int, int]:
    """(I, V, T_1). I = T_1 - N_1. Proportional LP deposits and redemptions scale T_1, N_1 and V together (up to one
    unit of rounding each), so they leave I / V unchanged; only trades move I, and a trade moves it by exactly the
    currency1 it moves."""
    t1 = snap.shares * cfg.target_per_share // WAD
    v = min(cfg.depth_max, snap.shares * cfg.depth_per_share // WAD)
    return t1 - snap.n1, v, t1


def straddle_cap(depth: int, h: int, h_min: int) -> int:
    """Largest c >= 0 such that, for every |I| <= c, the curve's bid stays <= mid * (1 - h_min) and its ask stays
    >= mid * (1 + h_min), with half-spread h on each side:

        bid side, I = +c:   (1 - h) * (V / (V - c))^2 <= 1 - h_min    <=>  (V - c)^2 (PIPS - h_min) >= V^2 (PIPS - h)
        ask side, I = -c:   (1 + h) * (V / (V + c))^2 >= 1 + h_min    <=>  (V + c)^2 (PIPS + h_min) <= V^2 (PIPS + h)

    Exact integer search from an isqrt start. Returns 0 if h <= h_min (no room for any skew)."""
    if h <= h_min or depth == 0:
        return 0
    vv = depth * depth
    # bid side: smallest r = V - c with r^2 (PIPS - h_min) >= V^2 (PIPS - h)
    num, den = vv * (PIPS - h), PIPS - h_min
    r = isqrt(num // den)
    while r * r * den < num:
        r += 1
    c_bid = depth - r
    # ask side: largest s = V + c with s^2 (PIPS + h_min) <= V^2 (PIPS + h)
    num2, den2 = vv * (PIPS + h), PIPS + h_min
    s = isqrt(num2 // den2)
    while (s + 1) * (s + 1) * den2 <= num2:
        s += 1
    while s * s * den2 > num2:
        s -= 1
    c_ask = s - depth
    return max(0, min(c_bid, c_ask))


def depth_per_share_for(target_per_share: int, max_deviation: int, base_spread: int, min_edge: int) -> int:
    """Smallest depth per share (WAD) whose straddle cap at the base spread reaches the risk cap max_deviation * T_1.

    The straddle condition limits the curve's skew to the spread: at |I| = cap the inventory-reducing quote sits at the
    reference (less h_min) and the inventory-increasing quote at about reference * (1 + 2h). So the depth is not a free
    parameter. It follows from three economic ones: how much inventory the vault may carry (max_deviation), how wide
    it quotes (base_spread) and the minimum edge it keeps (min_edge). Approximately V = I_max / (sqrt((1+h)/(1+h_min))
    - 1), about 2 I_max / (h - h_min). Computed for one share-unit of 10^24 shares and then checked exactly with the
    integer `straddle_cap`; configuration-time only (never on the swap path)."""
    if base_spread <= min_edge:
        raise Revert("InvalidConfig")
    s = 10**24
    i_max = s * target_per_share // WAD * max_deviation // PIPS
    ratio = ((PIPS + base_spread) / (PIPS + min_edge)) ** 0.5 - 1
    dps = int(i_max / ratio * WAD // s)
    while straddle_cap(s * dps // WAD, base_spread, min_edge) < i_max:
        dps += dps // 10_000 + 1
    return dps


def ext_cost(i: int, depth: int, price_x96: int, cap: int) -> int:
    """ceil(C_ext(I)): Hook B's curve inside [-cap, cap], continued linearly with the slope it has at the edge.

    Inside the cap this is exactly `position_cost`. Outside, the marginal price is frozen at its value at the edge, so
    the potential is defined (and convex) for every I, an inward trade from beyond the cap can always be priced, and
    its bid never crosses the straddle bound. With c = cap, V = depth, P = price:

        I >  c:  C = V * Q96 * (c (V - c) + (I - c) V) / (P (V - c)^2)
        I < -c:  C = -V * Q96 * (c (V + c) + (|I| - c) V) / (P (V + c)^2)

    Both equal C(+-c) at the edge, so the function is continuous and its ceiling is one integer function: any trade is
    priced as a difference of two of its values and telescopes."""
    if -cap <= i <= cap:
        return position_cost(i, depth, price_x96)
    if i > cap:
        return mul_div_up(depth * Q96, cap * (depth - cap) + (i - cap) * depth, price_x96 * (depth - cap) ** 2)
    y = -i
    return -mul_div(depth * Q96, cap * (depth + cap) + (y - cap) * depth, price_x96 * (depth + cap) ** 2)


def ext_position_for_cost(t: int, depth: int, price_x96: int, cap: int) -> int:
    """Largest integer I with C_ext(I) <= t, for t <= ext_cost(cap) (callers refuse targets above the cap first).

    For integer t, ceil(C) <= t  <=>  C <= t, so this inverts `ext_cost` exactly."""
    lo_cost = ext_cost(-cap, depth, price_x96, cap)
    if t >= lo_cost:
        return position_for_cost(t, depth, price_x96)
    # Linear part below -cap: need V*Q96*(c(V+c) + (y-c)V) >= -t * P * (V+c)^2, smallest such y.
    c = cap
    need = -t * price_x96 * (depth + c) ** 2 - depth * Q96 * c * (depth + c)
    y = c + mul_div_up(need, 1, depth * depth * Q96)
    return -y


def quote_inventory(cfg: InventoryConfig, snap: VaultSnapshot, ref: Reference, zero_for_one: bool,
                    amount_in: int) -> InventoryQuote:
    """Candidate C, exact input. Refuses with a named reason instead of pricing what it cannot price safely.

    zeroForOne (trader sells currency0, vault sells currency1, I rises):
        t  = C_hat(I) + floor(amountIn * PIPS / (PIPS + h)) - 1
        I' = largest I' with C_hat(I') <= t;  out = I' - I;  refused if I' > cap.
    oneForZero (trader sells currency1, vault buys it, I falls by amountIn):
        I' = I - amountIn;  out = floor((C_hat(I) - C_hat(I')) * (PIPS - h) / PIPS) - 1;  refused if I' < -cap.

    The "- 1" on each side. C_hat is a ceiling, so C_hat(b) - C_hat(a) can exceed the exact C(b) - C(a) by up to one
    raw unit. Reserving one unit per trade makes every fill satisfy the straddle bound exactly (not just up to a
    unit), for every trade size: without it a dust trade can land one wei on the trader's side of the reference.

    h = base_spread + reference uncertainty. cap = min(straddle_cap(V, h, h_min), max_deviation * T_1 / PIPS).
    """
    if amount_in == 0:
        raise Revert("ZeroInput")
    if amount_in > MAX_AMOUNT:
        raise Revert("AmountTooLarge")
    h = cfg.base_spread + ref.uncertainty
    if h > cfg.max_spread:
        raise Revert("SpreadTooWide", h)
    i, v, t1 = inventory_state(cfg, snap)
    if v == 0:
        raise Revert("NoDepth")
    cap = min(straddle_cap(v, h, cfg.min_edge), t1 * cfg.max_deviation // PIPS)
    P = ref.price_x96
    c_i = ext_cost(i, v, P, cap)
    if zero_for_one:
        t = c_i + credit_in(amount_in, h) - 1
        if i >= cap or t >= ext_cost(cap + 1, v, P, cap):
            raise Revert("InventoryLimit", i, cap)
        i2 = ext_position_for_cost(t, v, P, cap)
        out = i2 - i
    else:
        i2 = i - amount_in
        if i2 < -cap:
            raise Revert("InventoryLimit", i, cap)
        out = debit_out(c_i - ext_cost(i2, v, P, cap), h) - 1
    if out <= 0:
        raise Revert("ZeroOutput")
    return InventoryQuote(out, i, i2, h, cap, v)
