# Proposal: After‑Tax Account & Portfolio Valuation — a country‑configurable tax module

**Status:** Draft / RFC
**Scope:** Add a page that shows each account's and the whole portfolio's value *after tax*, backed by a global, per‑country configurable tax‑rules module.
**Audience:** Maintainers evaluating the feature and the module design before implementation.

> ⚠️ **Not tax advice.** Everything here produces *estimates* for planning. The UI must say so, and the model must degrade gracefully (show pre‑tax value) when a jurisdiction is not configured.

---

## 1. Goal

Today Sure shows **pre‑tax** value everywhere: `BalanceSheet#net_worth`, `Account#balance`, `Holding#amount`. A tax‑exempt ISA holding and a fully‑taxable brokerage holding with a large unrealized gain look identical on the net‑worth screen, even though liquidating them yields very different amounts.

We want a new **"After tax" view** that estimates, per account and for the whole portfolio:

- **Embedded (latent) tax** — tax that would be owed if positions with unrealized gains were sold today.
- **Wrapper‑adjusted value** — accounts inside tax‑advantaged wrappers (ISA, Roth IRA, TFSA, PEA, PPF…) carry little or no latent tax; tax‑deferred wrappers (401(k), RRSP, SIPP, PER…) carry deferred income tax on the *whole* balance, not just the gain.
- **After‑tax net worth** — pre‑tax net worth minus estimated latent tax across all accounts.

The hard part is not the arithmetic — it is that **tax rules differ by country, by household situation, by product, and by personal status** (senior, disabled, veteran, church member, province/state). So the core deliverable is a **module that lets us configure rules per country** and add new countries without touching the calculation engine.

---

## 2. Which countries to support first

### 2.1 Evidence gathered from the codebase and community

The repo already encodes a de‑facto country priority in several places:

| Signal | Source | Countries / regions implied |
|---|---|---|
| Investment account **subtypes with `tax_treatment`** | `app/models/investment.rb` (`SUBTYPES`, `region:` keys) | **US, UK, Canada, Australia, EU (France/Germany/Switzerland), India** |
| Depository **tax‑advantaged subtypes** | `app/models/depository.rb` (`hsa`) | US |
| **Currency → region** prioritization map | `Investment::CURRENCY_REGION_MAP` | USD→us, GBP→uk, CAD→ca, AUD→au, EUR→eu, CHF→eu, INR→in |
| `families.country` column (default `"US"`) | `db/schema.rb` | already a per‑family country field exists |
| Community **UI translations** (`config/locales/**` — Doorkeeper + views) | de, fr, nl, it, ca/es, hu, ro, ru, tr, vi, zh‑CN, zh‑TW | Germany, France, Netherlands, Italy, Spain/Catalonia, Hungary, Romania, Russia, Turkey, Vietnam, China/Taiwan |
| Contributor email domains (`git log`) | `.uk`, `gariasf.com` (ES/CA), `jjmata.com`, `.com` | UK, Spain, Anglosphere |

Two independent signals — the **tax regions the maintainers already hand‑modeled** and the **languages the community actually translated** — converge on a Europe‑heavy set plus the Anglosphere plus India.

### 2.2 Recommended rollout tiers

| Tier | Countries | Why |
|---|---|---|
| **Tier 1 (launch)** | 🇺🇸 US · 🇬🇧 UK · 🇨🇦 Canada · 🇩🇪 Germany · 🇫🇷 France | Already have wrapper subtypes (US/UK/CA/FR), largest translated communities (de/fr), and cover the three main tax *archetypes* below. |
| **Tier 2** | 🇦🇺 Australia · 🇮🇳 India · 🇳🇱 Netherlands · 🇮🇹 Italy · 🇪🇸 Spain | Existing subtypes (AU/IN) + strong translation communities (nl/it/es). |
| **Tier 3 / community** | 🇨🇭 Switzerland, 🇮🇪 Ireland, 🇵🇱 Poland, 🇷🇴 Romania, 🇹🇷 Turkey, … | Added via config PRs once the schema is stable. |
| **Everything else** | Generic fallback | A single configurable "flat effective CGT rate" jurisdiction so the feature *technically fits all countries* from day one (see §6). |

Picking Tier 1 to span the archetypes matters more than raw count, because the module design must be validated against genuinely different systems:

- **Marginal‑rate + holding period** — US (short vs long term, added to income), Canada (50% inclusion then marginal), Australia (50% discount then marginal), India (STCG vs LTCG).
- **Flat withholding** — Germany (Abgeltungsteuer ~26.375%), France (PFU 30%).
- **Allowance + banded** — UK (£3,000 annual exempt amount, then 18%/24% by income band).

If the config schema can express all three cleanly, it can express almost anything.

---

## 3. Tax dimensions that change the after‑tax number

The user's brief explicitly calls out *person, household, per‑product, veteran, handicapped, etc.* These map to four orthogonal inputs. The module needs all four:

1. **Jurisdiction (country, sometimes sub‑region)** — the rate tables, allowances, and wrapper rules. Sub‑region matters: Canadian provinces, US states, German church‑tax states, Swiss cantons.
2. **Product / account wrapper** — already partly modeled as `Investment#tax_treatment ∈ {taxable, tax_deferred, tax_exempt, tax_advantaged}`. This is the single most important lever and it already exists.
3. **Household / filing status** — single, married filing jointly/separately, civil partnership, head of household. Changes both the rate bands and the size of allowances (e.g. Germany's Sparerpauschbetrag €1,000 single / €2,000 joint; US 0% LTCG bracket doubles for MFJ).
4. **Personal status modifiers** — senior/super‑senior, disability, veteran, church membership, tax residency/domicile. These flip specific exemptions on and off.

#### How much do "veteran / handicapped / senior" actually matter here?

For this feature specifically — estimating **latent tax on unrealized capital gains** — most personal‑status flags do **not** move the number, and should be treated as *optional, opt‑in* config rather than core logic:

| Status | Affects the CGT estimate? | Reality |
|---|---|---|
| **Veteran** | ❌ Essentially never | Benefits (e.g. US VA disability pay) are tax‑exempt *income*; some US states give veterans *property‑tax* relief (a recurring cost on a Property account, not a latent sale tax). No general capital‑gains break. |
| **Disabled / handicapped** | ⚠️ Only indirectly | Disability‑gated *accounts* (Canada RDSP, etc.) are already captured by the subtype → `tax_treatment`, so the wrapper handles it — no person‑level flag needed for valuation. Other reliefs (India 80U/80DD…) are income‑side. |
| **Senior / super‑senior** | ⚠️ Mostly no | Higher basic exemptions are income‑side; equity LTCG keeps its own exemption regardless of age (e.g. India ₹1.25L). Senior products (SCSS) are subtypes, not flags. |

The modifiers that **genuinely change the capital‑gains estimate** and are worth building are: **filing/household status** (allowance size + brackets), **taxable income** (band selection for marginal‑rate countries), **church membership** (Germany, +8–9% on the tax itself), and **subregion** (province/state/canton rate).

**Decision:** do not build veteran/handicapped tax logic in the MVP. Keep `status_flags` (§5.1) an open JSONB so a country's YAML can *opt in* to reading a flag (as `de.yml` reads `church_member`); community PRs add per‑jurisdiction nuances later. Guardrails: (a) where a status gates a *product*, the subtype/`tax_treatment` already covers it — no duplicate person‑flag logic; (b) modeling full personal‑status tax breaks pushes the app toward tax‑prep, which conflicts with the "estimate, not advice" framing.

### 3.1 Per‑country reference (Tier 1 + 2), tax year 2025/26

Values are illustrative defaults to seed the config; they change yearly, so they live in versioned config, never in code (§5.3).

| Country | Capital‑gains model | Key allowance / exemption | Product wrappers (→ `tax_treatment`) | Household effect | Status modifiers |
|---|---|---|---|---|---|
| **US** 🇺🇸 | LTCG 0/15/20% if held >1yr; STCG = ordinary income (10–37%); +3.8% NIIT high earners | 0% LTCG bracket up to ~$48,350 single / ~$96,700 MFJ | 401(k)/IRA→deferred; Roth→exempt; HSA/529→advantaged; brokerage→taxable | Filing status sets brackets & NIIT threshold | State CGT varies; veteran/disability mostly affect *income*, some state property breaks |
| **UK** 🇬🇧 | 18% (basic band) / 24% (higher) on gains | £3,000 annual exempt amount; £500 dividend allowance | ISA/LISA→exempt; SIPP/workplace pension→deferred | Independent taxation; allowance is per‑person, not shared | — |
| **Germany** 🇩🇪 | Flat Abgeltungsteuer 25% + 5.5% soli = **26.375%** | Sparerpauschbetrag €1,000 single / €2,000 joint | Riester/pension→deferred | Joint filing doubles saver's allowance | **Church tax** (Kirchensteuer) +8–9% for members |
| **France** 🇫🇷 | Flat tax **PFU 30%** (12.8% IR + 17.2% social); 2026: 31.4% | Livret A etc. fully exempt; assurance‑vie abatement after 8yrs | PEA→advantaged (exempt after 5yrs); assurance‑vie→advantaged; PER→deferred | *Foyer fiscal* (household) is the tax unit | Older AV contracts, holding‑period rules |
| **Canada** 🇨🇦 | 50% inclusion rate, then marginal (federal + **province**) | Principal residence exemption; LCGE ($1.25M for qualifying) | TFSA/FHSA→exempt; RRSP/RRIF/LIRA→deferred; RDSP→disability‑advantaged | Spousal attribution rules | **RDSP is disability‑gated**; province changes rate |
| **Australia** 🇦🇺 | Marginal rate on gain, **50% discount** if held >12 months | — | Super/SMSF→deferred (concessional 15%) | — | Seniors/pensioners offsets |
| **India** 🇮🇳 | Equity LTCG 12.5% over ₹1.25L; STCG 20%; other assets differ | ₹1.25 lakh equity LTCG exemption/yr | PPF/SSY/tax‑free bonds→exempt; NPS/APY→advantaged; ELSS→advantaged | — | **Senior / super‑senior** higher basic exemption; disability deductions (income side) |
| **Netherlands** 🇳🇱 | Box 3 deemed‑return wealth tax (not realized‑gain based) | Tax‑free wealth allowance (heffingsvrij vermogen) | Pension (box 1) deferred | Fiscal partners pool box‑3 allowance | — |
| **Italy** 🇮🇹 | Flat 26% on most financial gains (12.5% on govt bonds) | — | Pension funds concessional | — | — |
| **Spain** 🇪🇸 | Savings‑income bands 19–28% | — | Pension plans deferred | — | Regional (autonomía) variations |

The Netherlands entry is deliberately included to prove a point: **not every country taxes realized gains at all.** The Dutch Box‑3 system taxes a *deemed return on wealth*. The module must therefore treat "how latent tax is computed" as a per‑jurisdiction *strategy*, not a single formula (§5.4).

---

## 4. What already exists (the seam to build on)

We are not starting from scratch. The calculation can hang off existing structures:

- **`families.country`** (`string`, default `"US"`) — jurisdiction selector already persisted per family.
- **`Investment#tax_treatment`** → `:taxable | :tax_deferred | :tax_exempt | :tax_advantaged`, derived from `SUBTYPES[subtype][:tax_treatment]`. This is exactly the wrapper lever we need.
- **`Depository#tax_advantaged?`** (HSA) — same idea for cash accounts.
- **`Holding#amount` / `#avg_cost` / `#trend`** — market value, cost basis, and thus **unrealized gain per lot are already computed** (`Holding#trend` is literally `current − cost_basis`). Latent CGT = f(unrealized gain, jurisdiction, profile).
- **`BalanceSheet`** — the natural place to add an `after_tax` variant; it already aggregates assets/liabilities in the family currency and handles FX via `Money`.
- **`Money` / `Monetizable`** — currency conversion and formatting already solved.

So the new module needs to add: (a) a **tax profile** (the household/status inputs), (b) a **jurisdiction registry** (the per‑country config), and (c) a **calculator** that combines them with existing holdings. Everything else is presentation.

---

## 5. Proposed module design

Idiomatic to this codebase: **fat models + POROs, no `app/services/`, data‑driven config, minimize dependencies** (per `CLAUDE.md`). Namespaced under `Tax::`.

```
app/models/tax/
  profile.rb            # ActiveRecord: per-family (opt. per-user) household + status inputs
  jurisdiction.rb       # PORO: loads + wraps one country's config, exposes a rules interface
  registry.rb           # PORO: loads all config/tax/*.yml, resolves country -> Jurisdiction (+ fallback)
  rule_set.rb           # PORO: value object for one country's rate tables/allowances/wrappers
  liability.rb          # PORO: result object (gross_gain, taxable_gain, tax, effective_rate, breakdown)
  calculators/
    realized_gain.rb    # strategy: US/UK/CA/AU/DE/FR/IN — latent tax on unrealized gains
    deemed_return.rb    # strategy: NL Box-3 style
    flat_rate.rb        # strategy: generic fallback
app/models/account/taxable.rb   # concern: Account#latent_tax, #after_tax_value
config/tax/
  us.yml  uk.yml  de.yml  fr.yml  ca.yml  au.yml  in.yml  nl.yml ...  _fallback.yml
```

### 5.1 `Tax::Profile` (the person/household/status inputs)

A new table, one row per family (optionally per user for shared families), holding the §3 inputs:

```ruby
# t.references :family
# t.string  :filing_status          # single | married_jointly | married_separately | civil_partnership | head_of_household
# t.string  :subregion              # e.g. "US-CA", "CA-ON", "DE-BY", "CH-ZH" — optional
# t.integer :taxable_income_cents    # optional; needed for marginal-rate jurisdictions (US/UK/CA/AU/IN)
# t.jsonb   :status_flags, default: {}   # { senior: true, disabled: true, veteran: true, church_member: true }
# t.jsonb   :allowance_usage, default: {} # how much of annual allowance already used elsewhere
```

`status_flags` as JSONB keeps it open: a country config declares which flags it *reads* (Germany reads `church_member`, Canada reads `disabled` for RDSP, India reads `senior`), and the UI only renders flags relevant to the family's country. Unknown flags are simply ignored by jurisdictions that don't reference them.

Defaults are safe: no profile → assume `single`, no income, no flags → the calculator falls back to the jurisdiction's headline rate. The feature works before the user fills anything in.

### 5.2 `Tax::Jurisdiction` + `Tax::Registry`

```ruby
jurisdiction = Tax::Registry.for(family.country)   # -> Tax::Jurisdiction, or fallback
liability    = jurisdiction.latent_tax(holding, profile: family.tax_profile)
```

`Registry` loads every `config/tax/*.yml` once (memoized), maps ISO country code → `Jurisdiction`, and returns the generic fallback jurisdiction for anything unconfigured. Adding a country = **dropping a YAML file + a locale entry. No engine changes.**

### 5.3 Config schema (rates live in versioned data, not code)

Rates change every tax year and must be auditable, so they are declarative YAML keyed by tax year:

```yaml
# config/tax/de.yml
country: DE
currency: EUR
strategy: realized_gain          # which Tax::Calculators::* to use
tax_years:
  "2025":
    capital_gains:
      kind: flat                 # flat | marginal_bands | inclusion | discount
      rate: 0.25
      surcharges:
        solidarity: 0.055        # of the tax, => 26.375% effective
        church_tax:              # applied only when profile.status_flags.church_member
          when_flag: church_member
          rate: 0.09
    allowances:
      saver:
        amount: 1000
        joint_amount: 2000       # used when filing_status == married_jointly
        applies_to: [capital_gains, dividends, interest]
    wrappers:                    # override by tax_treatment (falls back to sensible defaults)
      tax_exempt:   { latent_tax_rate: 0.0 }
      tax_deferred: { basis: full_balance, note: "income tax on withdrawal — estimated" }
```

```yaml
# config/tax/uk.yml (excerpt) — allowance + banded archetype
capital_gains:
  kind: marginal_bands
  bands:
    - { up_to_income: basic_rate_limit, rate: 0.18 }
    - { rate: 0.24 }
allowances:
  annual_exempt_amount: { amount: 3000, per: person }
```

Design choices baked into the schema:

- **`strategy`** selects the calculator class → the Netherlands can use `deemed_return` while everyone else uses `realized_gain`, with no special‑casing in the engine.
- **`tax_years`** makes rate updates a one‑line PR and lets historical net‑worth charts use period‑correct rates later.
- **`wrappers`** keyed by the *existing* `tax_treatment` enum means the wrapper→treatment mapping we already maintain in `Investment::SUBTYPES` is the single source of truth; the country file only says what each treatment *costs*.
- **`when_flag` / conditional allowances** express veteran/disability/senior/church modifiers declaratively.

#### 5.3.1 CGT that depends on household income, and electable methods (France)

Two related realities the schema must handle:

**(a) The rate depends on household income.** In the US (LTCG 0/15/20 bracket), UK (18 vs 24 band), Canada/Australia (gain stacked on marginal income) and India (slab for non‑112A assets), the tax on a gain depends on total household income. This is why `Tax::Profile.taxable_income_cents` exists and why marginal calculators **stack the gain on top of household income** to find the marginal rate. For household‑tax‑unit countries (France *foyer fiscal*, US *married filing jointly*) `taxable_income_cents` is the **household** figure, not an individual's.

**(b) The taxpayer can elect between methods (France PFU vs barème).** For most French capital income the household may choose, on the annual return (case *2OP*), between the flat **PFU (30%)** and the progressive **barème** (household income‑tax scale + 17.2% social levies, with a 40% dividend abatement, pre‑2018 holding‑period abatements, and 6.8% CSG deductible). The choice is **global for the year and for all capital income** — not per product — so it is a household setting applied **once at the BalanceSheet level**, exactly where annual allowances are netted (§5.4). Some products are outside the choice entirely (PEA >5 yrs, Livret A → already `tax_exempt`; assurance‑vie has its own regime).

The schema expresses this with `methods` + an `election` mode and a reusable progressive `income_tax_scale`:

```yaml
# config/tax/fr.yml (illustrative — seed values, updated per tax year)
country: FR
currency: EUR
strategy: electable_gain            # compute each method, elect per `election`
tax_years:
  "2025":
    capital_gains:
      election: most_favorable      # most_favorable | pfu | bareme  (household preference)
      methods:
        pfu:
          kind: flat
          rate: 0.128               # income-tax portion
          social_levies: 0.172      # always applies
        bareme:
          kind: marginal_scale
          scale: income_tax_scale   # references the household brackets below
          social_levies: 0.172
          csg_deductible: 0.068     # barème only
          abatements:
            dividends: 0.40                       # 40% abattement (barème only)
            securities_pre_2018: { by_holding_period: true }
    income_tax_scale:               # progressive household (foyer fiscal) IR brackets
      - { up_to: 11497,  rate: 0.0  }
      - { up_to: 29315,  rate: 0.11 }
      - { up_to: 83823,  rate: 0.30 }
      - { up_to: 180294, rate: 0.41 }
      - { rate: 0.45 }
    wrappers:
      tax_exempt: { latent_tax_rate: 0.0 }        # PEA >5y, Livret A
```

`Tax::Calculators::ElectableGain` computes each method and returns the one selected by `election` (default: the smaller tax). Because the election and the progressive scale need the **whole** household picture, the *final* election is resolved at `BalanceSheet#after_tax_net_worth` (which already aggregates all gains and applies allowances once); per‑holding numbers shown in the UI are the marginal‑attributed share of that household‑level result, and the "estimate, not advice" disclaimer covers the simplification. The `income_tax_scale` block is reusable — marginal‑rate countries (US/UK/CA/AU/IN) reference the same structure instead of duplicating bracket logic.

### 5.4 Calculation flow (per holding → account → portfolio)

```
for each Holding in Account:
  treatment      = holding.account.accountable.tax_treatment      # existing
  unrealized_gain = holding.trend.value  (market_value - cost_basis)   # existing
  liability      = Tax::Registry.for(family.country)
                      .calculator                                  # by strategy
                      .call(gain: unrealized_gain,
                            treatment: treatment,
                            wrapper_balance: holding.amount,
                            profile: family.tax_profile,
                            year: Date.current.year)
Account#latent_tax   = Σ holding liabilities (+ cash / deposit-interest rules)
Account#after_tax_value = balance - latent_tax
Portfolio            = BalanceSheet#after_tax_net_worth = Σ accounts after allowances applied once
```

Treatment shortcuts the maths:

- `tax_exempt` → latent tax = 0 (ISA, Roth, TFSA, PEA‑after‑5yrs, PPF).
- `tax_deferred` → estimate on **full balance** at an assumed income‑tax rate (401(k)/RRSP/SIPP), clearly labeled "deferred income tax, estimated."
- `taxable` → run the jurisdiction's realized‑gain calculator on the **gain only**, net of the annual allowance.
- `tax_advantaged` → jurisdiction‑specific (often partial); config decides.

**Allowances are portfolio‑level, not per‑holding**, so the annual exempt amount (UK £3k, DE saver's allowance, India ₹1.25L) is applied once by `BalanceSheet#after_tax_net_worth` against total taxable gains — not multiplied across every lot. This is why the calculator returns a *taxable_gain breakdown*, and the BalanceSheet does the final allowance netting.

### 5.5 UI

- New **"After tax"** toggle/tab on the net‑worth / balance‑sheet page (Hotwire, query‑param state per Convention 3).
- Per‑account: show pre‑tax balance, estimated latent tax, after‑tax value, and a wrapper badge (Exempt / Deferred / Taxable) reusing the existing `tax_treatment`.
- Settings → a **Tax profile** form (country prefilled from `families.country`, filing status, optional income, status flags relevant to the country).
- Prominent "estimate, not advice" disclaimer; graceful "not yet configured for <country> — showing pre‑tax" state.

---

## 6. Fitting *all* countries

Two mechanisms make the claim "fits all countries" true without configuring all ~200:

1. **`config/tax/_fallback.yml`** — a generic jurisdiction with a single, user‑editable **flat effective CGT rate** (default e.g. 15%, or 0 to disable). Any `family.country` with no dedicated file resolves here, so the after‑tax page always renders *something* sensible, and the user can override the rate in their tax profile.
2. **Config‑only country onboarding** — because rules are declarative YAML + a locale string, a new country is a data PR reviewed by someone who knows that tax system, never a change to the calculation engine. This is how the project already scales `Investment::SUBTYPES` by region.

---

## 7. Phased rollout

1. **Phase 0 — plumbing:** `Tax::Profile` model + migration, `Tax::Registry`/`Jurisdiction`/`RuleSet` POROs, `_fallback.yml`, `flat_rate` calculator. Wire `Account#latent_tax` and `BalanceSheet#after_tax_net_worth`. Ship the page with fallback‑only rates behind `preview_features_enabled?`.
2. **Phase 1 — Tier‑1 configs:** `us/uk/de/fr/ca.yml` + `realized_gain` calculator (flat, marginal_bands, inclusion, discount kinds). Tax‑profile settings form. Wrapper badges.
3. **Phase 2 — Tier‑2 + strategies:** `au/in/nl/it/es.yml`; add `deemed_return` calculator for NL. Household + status‑flag modifiers.
4. **Phase 3 — polish:** period‑correct historical rates, subregion (province/state/canton) support, per‑user profiles for shared families, CSV/API exposure of after‑tax figures.

## 8. Testing & correctness

- Minitest + fixtures per `CLAUDE.md`. Table‑driven tests: for each jurisdiction, a fixture holding with a known gain + profile → asserted latent tax (golden numbers from the reference tables in §3.1).
- Test each **strategy** once thoroughly (flat, marginal_bands, inclusion, discount, deemed_return, flat_rate); test each **country file** only for its distinctive rule (DE church tax, UK allowance netting, CA province, IN senior exemption).
- Property test: `tax_exempt` wrapper ⇒ latent tax always 0; after‑tax value ≤ pre‑tax value for asset accounts.
- No external API dependency, so no VCR needed.

## 9. Open questions

- Should latent tax on **tax‑deferred** balances be shown by default, or opt‑in? (It can dwarf CGT and surprise users.)
- Do we net **capital losses** across accounts before applying gains? (Recommended: yes, at BalanceSheet level, mirroring real loss‑harvesting.)
- Per‑**user** vs per‑**family** tax profile for shared families with different residencies.
- How aggressively to model **income‑tax‑on‑withdrawal** for pensions vs. a flat assumed rate.
```
