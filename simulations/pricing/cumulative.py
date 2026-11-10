"""Integer reference model of Porkfolio's cumulative pricing (Hook A and Hook B) and of the pricing it replaces.

Every function here mirrors, operation by operation, the integer arithmetic the Solidity hooks perform, so the model
produces the exact raw amounts the contracts must produce. Python integers are unbounded; overflow is analysed in the
Solidity NatSpec, not here. `fractions.Fraction` is used only for the *real-valued* curves C(x) that the integer
functions round, so that rounding claims can be checked against exact rationals.

Units
-----
- Amounts are raw token units (integers).
- priceX96 is the hook's reference price: raw currency1 per raw currency0, Q64.96 (as in `_grossOut`).
- Fees and impact limits are in pips: 1,000,000 pips = 100%.
- Time is in seconds.

Nothing in this file is historical market data. It is a deterministic model of formulas.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from fractions import Fraction
from math import isqrt

Q96 = 2**96
PIPS = 1_000_000
MAX_AMOUNT = 2**127 - 1
MAX_LEVEL = 2**128 - 1  # Hook A flow level is stored as uint128
MAX_DEPTH = 2**95 - 1  # Hook B depth bound that keeps every product below 2^256 (see CumulativePricing.sol)


class Revert(Exception):
    """A contract revert. `name` is the custom error the Solidity code uses."""

    def __init__(self, name: str, *args):
        super().__init__(name, *args)
        self.name = name
        self.args_ = args


# ----------------------------------------------------------------------------------------------------------------
# Integer helpers with the rounding of FullMath.mulDiv / mulDivRoundingUp
# ----------------------------------------------------------------------------------------------------------------


def mul_div(a: int, b: int, d: int) -> int:
    assert a >= 0 and b >= 0 and d > 0
    return a * b // d


def mul_div_up(a: int, b: int, d: int) -> int:
    assert a >= 0 and b >= 0 and d > 0
    return -((-a * b) // d)


def gross_out(price_x96: int, zero_for_one: bool, amount_in: int) -> int:
    """`BaseCompatibleHook._grossOut`: input converted at the reference price, rounded down."""
    return mul_div(amount_in, price_x96, Q96) if zero_for_one else mul_div(amount_in, Q96, price_x96)


def decayed(level: int, rate: int, window: int, elapsed: int) -> int:
    """`CumulativePricing.decayed`: max(0, level - floor(rate * elapsed / window)); window 0 disables decay.

    Rounds the decayed amount down, so the level after decay is never below the exact linear decay."""
    if window == 0 or elapsed == 0:
        return level
    d = rate * elapsed // window
    return level - d if level > d else 0


def decayed_signed(x: int, rate: int, window: int, elapsed: int) -> int:
    m = decayed(abs(x), rate, window, elapsed)
    return m if x >= 0 else -m


# ----------------------------------------------------------------------------------------------------------------
# Hook A: cumulative fee over gross input, per (pool, direction)
# ----------------------------------------------------------------------------------------------------------------


def fee_real(level: int, scale: int, base: int, mx: int) -> Fraction:
    """F(s) = integral from 0 to s of m(u) du / PIPS, m(u) = base + (max - base) * min(1, u / K). Input units."""
    if level <= scale:
        return Fraction(level * ((mx - base) * level + 2 * scale * base), 2 * scale * PIPS)
    return Fraction(scale * (base + mx) + 2 * mx * (level - scale), 2 * PIPS)


def cumulative_fee(level: int, scale: int, base: int, mx: int) -> int:
    """`CumulativePricing.cumulativeFee`: F_hat(s) = ceil(F(s)). Both branches agree at s = K."""
    if level <= scale:
        return mul_div_up(level, (mx - base) * level + 2 * scale * base, 2 * scale * PIPS)
    return mul_div_up(scale * (base + mx) + 2 * mx * (level - scale), 1, 2 * PIPS)


@dataclass
class HookAConfig:
    price_x96: int
    base: int
    mx: int
    scale0: int  # K for zeroForOne (input currency0)
    scale1: int  # K for oneForZero (input currency1)
    window: int  # seconds for a level of K to decay to zero; 0 = no decay

    def scale(self, zero_for_one: bool) -> int:
        return self.scale0 if zero_for_one else self.scale1


@dataclass
class HookA:
    cfg: HookAConfig | None = None
    level: dict = field(default_factory=lambda: {True: 0, False: 0})
    updated: dict = field(default_factory=lambda: {True: 0, False: 0})

    def configure(self, cfg: HookAConfig, now: int) -> None:
        if not (cfg.price_x96 > 0 and cfg.base <= cfg.mx < PIPS and 0 < cfg.scale0 <= MAX_LEVEL
                and 0 < cfg.scale1 <= MAX_LEVEL):
            raise Revert("InvalidConfig")
        if self.cfg is not None:  # settle elapsed decay under the old parameters, keep the level
            for d in (True, False):
                self.level[d] = self.level_now(d, now)
                self.updated[d] = now
        self.cfg = cfg

    def level_now(self, zero_for_one: bool, now: int) -> int:
        c = self.cfg
        return decayed(self.level[zero_for_one], c.scale(zero_for_one), c.window, now - self.updated[zero_for_one])

    def quote(self, zero_for_one: bool, amount_in: int, now: int):
        """Returns (amountOut, feeIn, newLevel). Mirrors HookA_DynamicFee._quote."""
        c = self.cfg
        if c is None:
            raise Revert("PoolNotConfigured")
        k = c.scale(zero_for_one)
        s = self.level_now(zero_for_one, now)
        s2 = s + amount_in
        if s2 > MAX_LEVEL:
            raise Revert("AmountTooLarge")
        fee = cumulative_fee(s2, k, c.base, c.mx) - cumulative_fee(s, k, c.base, c.mx)
        assert 0 <= fee <= amount_in
        out = gross_out(c.price_x96, zero_for_one, amount_in - fee)
        return out, fee, s2

    def swap(self, zero_for_one: bool, amount_in: int, now: int, min_out: int = 0) -> int:
        out, _fee, s2 = self.quote(zero_for_one, amount_in, now)
        if out == 0:
            raise Revert("ZeroOutput")
        if out < min_out:
            raise Revert("InsufficientOutput", out, min_out)
        self.level[zero_for_one] = s2
        self.updated[zero_for_one] = now
        return out


# ----------------------------------------------------------------------------------------------------------------
# Hook B: one signed position per pool on a virtual constant-product curve
# ----------------------------------------------------------------------------------------------------------------


def cost_real(x: int, depth: int, price_x96: int) -> Fraction:
    """C(x) = V * x * 2^96 / (P * (V - x)): currency0 owed for a net sale of x currency1, x < V (x may be < 0)."""
    return Fraction(depth * x * Q96, price_x96 * (depth - x))


def position_cost(x: int, depth: int, price_x96: int) -> int:
    """`CumulativePricing.positionCost`: C_hat(x) = ceil(C(x)) for every integer x with |x| < V."""
    assert abs(x) < depth
    if x >= 0:
        return mul_div_up(depth * x, Q96, price_x96 * (depth - x))
    y = -x
    return -mul_div(depth * y, Q96, price_x96 * (depth + y))


def position_for_cost(t: int, depth: int, price_x96: int) -> int:
    """`CumulativePricing.positionForCost`: the largest integer x with C(x) <= t (equivalently C_hat(x) <= t).

    C(x) <= t  <=>  x * (V * 2^96 + t * P) <= t * P * V, and V * 2^96 + t * P > 0 for every t > C(-inf) = -V*2^96/P."""
    if t >= 0:
        return mul_div(t * price_x96, depth, depth * Q96 + t * price_x96)
    u = -t
    den = depth * Q96 - u * price_x96
    assert den > 0
    return -mul_div_up(u * price_x96, depth, den)


def max_position(depth: int, max_impact: int) -> int:
    """`CumulativePricing.maxPosition`: the largest x >= 0 whose marginal price p(x) = P * (V / (V - x))^2 is at most
    P * (1 + maxImpact). (V/(V-x))^2 <= (PIPS + m)/PIPS  <=>  (V - x)^2 * (PIPS + m) >= V^2 * PIPS."""
    num, den = depth * depth * PIPS, PIPS + max_impact
    r = isqrt(num // den)
    while r * r * den < num:
        r += 1
    return depth - r


@dataclass
class HookBConfig:
    price_x96: int
    depth: int  # V, raw currency1
    max_impact: int  # pips
    window: int  # seconds for a position at the cap to decay to zero; 0 = no decay

    @property
    def xmax(self) -> int:
        return max_position(self.depth, self.max_impact)


@dataclass
class HookB:
    cfg: HookBConfig | None = None
    x: int = 0
    updated: int = 0
    rescale_on_depth_change: bool = True  # False models the rejected "keep raw x" rule, for comparison only

    def configure(self, cfg: HookBConfig, now: int) -> None:
        if not (cfg.price_x96 > 0 and 0 < cfg.max_impact < PIPS and 0 < cfg.depth <= MAX_DEPTH and cfg.xmax > 0):
            raise Revert("InvalidConfig")
        if self.cfg is not None:
            x = self.position_now(now)
            if self.rescale_on_depth_change and cfg.depth != self.cfg.depth:
                # Keep x / V (and so the marginal price) unchanged; truncate toward zero.
                x = (abs(x) * cfg.depth // self.cfg.depth) * (1 if x >= 0 else -1)
            self.x = x
            self.updated = now
        self.cfg = cfg

    def position_now(self, now: int) -> int:
        c = self.cfg
        return decayed_signed(self.x, c.xmax, c.window, now - self.updated)

    def quote(self, zero_for_one: bool, amount_in: int, now: int):
        """Returns (amountOut, newPosition, slack). Mirrors HookB_BoundedImpact._quote.

        zeroForOne: the trader pays currency0 and receives currency1; x rises by the output.
        oneForZero: the trader pays currency1 and receives currency0; x falls by the input."""
        c = self.cfg
        if c is None:
            raise Revert("PoolNotConfigured")
        V, P, xm = c.depth, c.price_x96, c.xmax
        x = self.position_now(now)
        if zero_for_one:
            t = position_cost(x, V, P) + amount_in
            if t >= position_cost(xm + 1, V, P):
                raise Revert("ImpactBoundExceeded", x, xm)
            x2 = position_for_cost(t, V, P)
            out = x2 - x
            slack = t - position_cost(x2, V, P)
        else:
            x2 = x - amount_in
            if x2 < -xm:
                raise Revert("ImpactBoundExceeded", x, xm)
            out = position_cost(x, V, P) - position_cost(x2, V, P)
            slack = 0
        assert out >= 0
        return out, x2, slack

    def swap(self, zero_for_one: bool, amount_in: int, now: int, min_out: int = 0) -> int:
        out, x2, _ = self.quote(zero_for_one, amount_in, now)
        if out == 0:
            raise Revert("ZeroOutput")
        if out < min_out:
            raise Revert("InsufficientOutput", out, min_out)
        self.x = x2
        self.updated = now
        return out


# ----------------------------------------------------------------------------------------------------------------
# Vault price floor (SharedCommitmentVault.exchange) and the pricing being replaced (for comparison)
# ----------------------------------------------------------------------------------------------------------------


def floor_ok(amount_in: int, amount_out: int, floor_x96: int) -> bool:
    """amountIn >= ceil(amountOut * floor / 2^96): the vault's PriceBelowFloor check."""
    return amount_in >= mul_div_up(amount_out, floor_x96, Q96)


def floors_consistent(f_sell0: int, f_sell1: int) -> bool:
    """The vault's directional-consistency rule: F_0 * F_1 >= 2^192."""
    return f_sell0 * f_sell1 >= Q96 * Q96


def old_hook_a_out(price_x96, base, mx, zero_for_one, amount_in, consumed, max_out) -> int:
    """HookA_DynamicFee before this change: fee from the allocation's post-trade utilisation."""
    gross = gross_out(price_x96, zero_for_one, amount_in)
    util = PIPS if max_out == 0 else min(PIPS, mul_div_up(consumed + gross, PIPS, max_out))
    fee = base + mul_div_up(mx - base, util, PIPS)
    return gross * (PIPS - fee) // PIPS


def old_hook_b_out(price_x96, k, cap, zero_for_one, amount_in, consumed, max_out) -> int:
    """HookB_BoundedImpact before this change: impact proportional to the trade's share of remaining quota."""
    gross = gross_out(price_x96, zero_for_one, amount_in)
    remaining = max_out - consumed
    if remaining == 0:
        return gross
    impact = mul_div_up(gross, k, remaining)
    if impact > cap:
        raise Revert("ImpactBoundExceeded", impact, cap)
    return gross * (PIPS - impact) // PIPS
