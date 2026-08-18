# US, UK & India: integrating three countries into the tax engine

This is a **working draft** built on the `feat/tax-configurable-rules` engine
(merged into this branch), following `docs/llm-guides/adding-a-tax-country.md`.
It adds three countries and folds in the parts of the earlier country-roadmap
proposal that the engine did not yet have (breadth, and the archetype coverage
that stress-tests the design). Everything is additive — no engine file's
behaviour changes except three new branches in `Tax::Registry.built_in`.

## What was added

| Area | Files |
|---|---|
| Rate data | `config/tax/us.yml`, `config/tax/gb.yml`, `config/tax/in.yml` |
| Generic rule | `app/models/tax/rules/cash_deposit.rb` |
| US rules | `app/models/tax/rules/us/{securities,deferred}.rb` |
| UK rules | `app/models/tax/rules/gb/{capital_gains,pension}.rb` |
| India rule | `app/models/tax/rules/in/equity.rb` |
| Wiring | `Tax::Registry` (`us_rules`/`gb_rules`/`in_rules`), `Tax::Catalogue`, `engine_test_helper` |
| Wording | 17 message keys in `Tax::Messages` + French in `tax_reports/fr.yml` |
| Tests | `test/models/tax/countries_engine_test.rb` (12 cases) |

Country codes are ISO alpha-2 to match `families.country`, so the UK file is
`gb.yml` (`country: GB`), not `uk.yml`.

## Archetype coverage (why these three)

The three validate that the engine can express genuinely different tax systems
without engine changes:

- **US — marginal + holding-period + preferential bracket.** Long-term gains at
  a correctable `long_term_gains` rate (0/15/20 assumed at the 15% middle band);
  pre-tax 401(k)/IRA taxed as income on the **whole balance**; Roth/HSA/529
  exempt. NIIT and state tax named as `unmodelled`.
- **UK — allowance + banded.** CGT 18% vs 24%, the band chosen from the
  household's declared marginal rate (≤20% → basic); ISA exempt; pension lump
  sum taxed on 75% of the balance.
- **India — equity LT/ST split.** Listed equity at 12.5% (§112A); PPF/SSY/tax-
  free bonds exempt; debt, small savings, NPS and insurance mapped to
  `NotModelled` because they turn on facts Sure does not hold.

## Where the engine's opinions overrode the original proposal

The earlier proposal wanted per-country **income-tax bracket tables** and a
**flat-rate fallback**. The engine deliberately rejects both, and its reasoning
held up here, so the draft follows the engine, not the proposal:

- **No bracket schedules.** Every marginal-rate country reuses the single
  household marginal rate the engine already collects. The UK rule maps that one
  number onto the 18/24 band; the US LTCG bracket is a correctable rate, not a
  schedule run against income Sure lacks.
- **Refuse, don't guess.** No `_fallback.yml` flat rate. An unmodelled Indian
  debt fund reports `tax = nil` and drops out of the total rather than inventing
  a number.

## Holding period & allowances — handled as *stated assumptions*

Two things Sure's data cannot support are surfaced on the report instead of
being faked:

- **Holding period.** `Subject` carries no per-lot acquisition date, so US and
  India assume **long-term** treatment (the common case for a net-worth view)
  and say so in a `:gap` warning. Short-term gains are named in `unmodelled`.
- **Annual allowances** (UK £3,000; India ₹1.25 lakh). These apply **once across
  all disposals in a year**, not per account — and the report is per account.
  Each figure therefore states that it *ignores* the allowance rather than
  netting it per row (which would over-count it across accounts).

### The one non-additive extension worth doing next

Properly *netting* those allowances is the single proposal element that the
engine cannot currently express, because it is inherently portfolio-level. The
clean way to add it mirrors what `Registry#apply_all` already does for
progressive-income stacking:

1. Add an optional `annual_allowance` block to a country file (an amount +
   which rate sections it applies to), read through a new `RateTable#allowance`.
2. In the portfolio pass (`apply_all` / `Snapshot`), after each rule returns its
   `taxable_base`, deduct the remaining allowance from the pooled taxable gain
   **once**, cheapest-rate-last, before the report totals the tax.

That is ~1 method on `RateTable` and a few lines in the portfolio pass — small,
but it does touch the core, so it is called out separately rather than smuggled
into a country file.

## Test status

Run in this environment (bare Ruby, no Rails/DB needed):

```
ruby -Itest test/models/tax/countries_engine_test.rb   # 12 runs, 0 failures
ruby -Itest test/models/tax/engine_test.rb             # 80 runs, 0 failures (regression)
ruby -Itest test/models/tax/formula_test.rb            # 46 runs, 0 failures
ruby -Itest test/models/tax/rate_overlay_test.rb       # 25 runs, 0 failures
```

Also verified in a bare process: all three YAML files load and resolve
period-correct rates; all 17 new message keys render; every one has a French
translation with matching placeholders and no literal `%`.

**Not run here:** `bin/rubocop` and the Rails-side suites (`messages_test`,
controller/integration tests) — this environment has Ruby 3.3.6 but the Gemfile
pins 3.4.9, so Bundler won't load. Those should be run in CI. Style was matched
to the surrounding engine code by hand.

## Follow-ups before this is production-ready

- Run `bin/rubocop -a` and the full Rails suite in CI (Ruby 3.4.9).
- Rate files carry seed values for tax-year 2025/26; confirm against current
  statute before shipping, and add the next year's entries as they are known.
- India debt/NPS and US short-term are intentionally `NotModelled`/assumed;
  revisit if Sure starts recording holding periods or debt accruals.
- Consider the allowance-netting extension above for the UK and India numbers to
  be complete rather than conservative.
