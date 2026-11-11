"""Loss bounds for correlated oracle failures under the proposed vault risk boundary.

Run from the repository root:  python3 simulations/mm/attacks.py

Every number is computed from a formula stated next to it, under assumptions printed with the table. The formulas follow
from the vault rules in `docs/architecture/ORACLE_RISK_BOUNDARY_SPEC.md`: the fill price is outside the reference band
(rule 2), the vault never pays out an asset below its inventory floor L_a = (1 - kappa) T_a (rule 3, no price), and each
asset's gross outflow is capped per flow window (existing vault flow caps). The simulated counterparts are in
`simulations/mm/results/phase142.md`. Model quantities only; nothing here is measured on chain.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Setup:
    holding: float = 1_000_000.0  # units of each asset held at target, price 1 (vault value 2,000,000)
    kappa: float = 0.15  # inventory tolerance
    flow_cap: float = 0.10  # gross outflow per asset per day, fraction of the target holding
    guardian_hours: float = 24.0  # time for the guardian to halt once something is visibly wrong (ASSUMPTION)
    honest_bracket: float = 0.0102  # widest honest source bracket half-width (RedStone WETH/USDC, verified thresholds)
    band: float = 0.0082  # reference uncertainty when both sources agree (fork-measured, WETH/USDC)


def units_at_risk(s: Setup, hours: float) -> float:
    """Units of one asset the vault can pay out before refusing, over a period of `hours`.

    The vault's flow windows are fixed one-day epochs, not rolling (`SharedCommitmentVault.FLOW_WINDOW`): an attack
    that straddles a boundary gets up to (ceil(T / 1 day) + 1) caps in T. So
    units = min((ceil(hours / 24) + 1) * flow_cap * holding, kappa * holding)."""
    import math
    caps = math.ceil(max(hours, 1e-9) / 24.0) + 1
    return min(caps * s.flow_cap * s.holding, s.kappa * s.holding)


def rows(s: Setup):
    value = 2 * s.holding
    out = []

    def add(name, detection, per_unit, units, note):
        loss = per_unit * units
        out.append((name, detection, f"{per_unit:.4f}", f"{units:,.0f}", f"{loss:,.0f}", f"{1e4 * loss / value:,.1f}",
                    note))

    # 1. One source manipulated by delta. Detected (empty intersection) once delta > sum of both brackets (~1.84%).
    #    Below that the honest bracket still contains the market and the intersection lies inside it, so a fill
    #    outside the intersection is at most the honest bracket's full width (2 d_h) from the market.
    add("one source manipulated, delta <= 1.84%", "none (inside both error bounds)", 2 * s.honest_bracket,
        units_at_risk(s, s.guardian_hours), "per-unit bound 2 d_h holds for any delta below detection")
    add("one source manipulated, delta > 1.84%", "ReferenceDivergence: refused", 0.0, 0.0, "fail closed")
    # 2./3. Both sources wrong by the same delta (shared upstream). Undetectable from the feeds; loss per unit is the
    #       mispricing beyond the band.
    for d in (0.03, 0.05, 0.20):
        add(f"both sources wrong by {d:.0%} (shared upstream)", "none from the feeds", max(0.0, d - s.band),
            units_at_risk(s, s.guardian_hours), "kappa and flow caps bound the units")
    # 4. Malicious or mistaken adapter after the 2-day timelock: any price. Loss per unit up to the unit's whole value,
    #    in both assets (the adapter can alternate which asset it undervalues).
    add("malicious adapter (any price), both assets", "timelock + guardian cancel before install", 1.0,
        2 * units_at_risk(s, s.guardian_hours), "the capital-at-risk bound: sum (N_a - L_a) p_a, rate-limited")
    # 5. Both feeds frozen through a move m, still inside their staleness limits (the deviation-trigger assumption
    #    fails). Loss per unit m - band until the limit (RedStone 6.5 h) or the guardian.
    for m in (0.05, 0.10):
        add(f"both feeds frozen through a {m:.0%} move", "staleness limit (6.5 h) or guardian", max(0.0, m - s.band),
            units_at_risk(s, 6.5), "units over 6.5 h")
    # 6. Sudden jump J: the feeds lag by one round (seconds to minutes). Loss per unit J - band during the lag; units
    #    limited by the flow cap still unused in that window.
    add("sudden 8% jump, one-round feed lag", "next round", max(0.0, 0.08 - s.band), units_at_risk(s, 0.1),
        "upper bound; the lag is usually much shorter than a flow window")
    # 7.-9. Fail-closed cases.
    add("feed misses its heartbeat past the staleness limit", "source dropped: InsufficientSources", 0.0, 0.0,
        "availability loss only")
    add("sequencer down, or within 1 h of restart", "SequencerUnavailable", 0.0, 0.0, "availability loss only")
    add("hook prices from a different configuration", "vault re-checks with its own adapter", 0.0, 0.0,
        "hooks read the adapter from the vault; a mismatch can only cause refusals")
    return out


def table(s: Setup) -> str:
    hdr = ("| scenario | detection | loss per unit (fraction of price) | units at risk (per asset) | loss (value) | "
           "loss (bps of vault) | note |\n|---|---|---|---|---|---|---|")
    return hdr + "\n" + "\n".join("| " + " | ".join(r) + " |" for r in rows(s))


def main():
    for s in (Setup(), Setup(flow_cap=0.40), Setup(kappa=0.05)):
        print(f"\n### kappa {s.kappa:.0%}, flow cap {s.flow_cap:.0%} of holding per asset per day, guardian "
              f"{s.guardian_hours:g} h (ASSUMPTIONS)\n")
        print(table(s))


if __name__ == "__main__":
    main()
