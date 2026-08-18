# Adding a Country to the Tax Module

The after-tax report ships with France. This guide covers what a second country
actually costs, and — as importantly — which parts of the module you must not
touch to add one.

The short version: **rates are a YAML file, rules are Ruby, and everything
else is already generic.** If you find yourself editing the overlay, the diff,
the rates screen, the rule builder or the validator to make your country work,
something is wrong with the design and not with your country. Say so in an
issue rather than patching around it.

## Architecture Overview

```text
config/tax/xx.yml            the numbers, effective-dated        ← you write this
  → Tax::RateTable            resolves a rate on a date
    → Tax::RateOverlay        lays a family's corrections on top  (generic)
      → Tax::Rules::Xx::*     what is taxed, and at what rate     ← you write this
        → Tax::Registry       maps Sure's (type, subtype) pairs   ← one line
          → Tax::Snapshot     the report
```

Key files:

- Rate file: `config/tax/xx.yml`
- Rule classes: `app/models/tax/rules/xx/*.rb`
- Registry mapping: `app/models/tax/registry.rb`
- Rule menu: `app/models/tax/catalogue.rb`
- Wording: `config/locales/views/settings/tax_rates/en.yml` (section names),
  `config/locales/views/settings/tax_rules/en.yml` (rate names, under `tax.rates`)

Nothing in the YAML is ever constantized. Editing a rate file can change a
number; it can never execute code. Keep it that way.

## What you do not have to write

These discover your country from the file itself, and adding a country must not
require changing any of them:

- **`Tax::RateOverlay.dated_sections`** finds your rate sections *by shape* — a
  top-level list whose entries each carry `effective_from` and `rate`. A
  section named `regional_surcharge` that this module has never heard of merges,
  validates, corrects and resolves on exactly the same path as
  `social_charges`. There is a test that invents one to prove it
  (`test/models/tax/rate_overlay_test.rb`).
- **The rates screen** (`Settings::TaxRatesController`) draws a row of boxes per
  dated entry per section, whatever the sections turn out to be.
- **`Tax::RateEdit.diff`** stores only what differs from the shipped file, so a
  family that corrects one figure still receives next year's other figures.
- **The rule builder** offers `Tax::RateTable#rate_names` — your file's sections
  plus its composites — as the rate menu.
- **`Tax::Formula#errors(known_rates:)`** validates rate names against your
  file. It does not carry a list of France's rates and must not grow one.

## Step 1: Write `config/tax/xx.yml`

The country code is the filename. `Tax.supported_countries` globs the directory,
so dropping the file in is what makes the module offer itself to a household
whose `families.country` is `XX`.

```yaml
country: XX
currency: EUR

# A rate section: any top-level list of entries carrying effective_from and
# rate. The name is yours. Nothing in Ruby needs to learn it.
#
# Rates are FRACTIONS. 0.186, not 18.6. The screens convert for the reader.
social_charges:
  - effective_from: 2018-01-01
    rate: 0.172
  - effective_from: 2026-01-01
    rate: 0.186

capital_gains_income_component:
  - effective_from: 2018-01-01
    rate: 0.128

# Rates made of other rates. Declared here rather than computed in Ruby, so
# that the parts and the total cannot drift apart, and so that a household
# writing a rule picks "flat_tax" from the same menu as "social_charges"
# without needing to know which of the two the file stores directly.
#
# A composite is a rate a rule may use and NOT a section anyone may correct:
# a box for the total would be a second place to change the same number.
composites:
  flat_tax: [ capital_gains_income_component, social_charges ]

# What a rule needs to know about each wrapper. A "product" is not a Sure
# subtype -- Sure files a tax-free savings account and a taxable one under the
# same subtype -- so it is sometimes declared per account instead.
#
# `ceiling` is always on cumulative payments in, never on current value.
products:
  some_wrapper:
    label: "Some Wrapper"
    maturity_years: 5
    ceiling: 150000

# Things this country taxes that the module deliberately does not model.
# Written down rather than omitted: the report names them so that an incomplete
# total says which parts are missing.
unmodelled:
  - id: life_insurance
    label: "Life insurance wrappers"
    reason: >-
      Taxation depends on the age of the contract and an annual allowance.
      Sure stores neither.
```

Every block is effective-dated and the engine picks the latest entry whose
`effective_from` is on or before the valuation date. That is what makes a
historic report still reproduce after a rate change, and it is why you can
commit next year's rate early.

**There is no income-tax scale here, and you should not add one.** Brackets
need the household's other income and its number of parts, neither of which
Sure knows; the module asks the household for a single marginal rate instead
(stored in `tax_households`, set under Settings → Taxes). "The rate your next
unit of income is taxed at" is a question with an answer in most countries;
a five-band schedule with a quotient familial is French statute.

## Step 2: Write the rule classes

A rule says *what* is taxed. It is Ruby because it is logic, and it is
hand-written per country because "gains are taxed only on withdrawal, and only
after five years" is not expressible as a number.

```ruby
# app/models/tax/rules/xx/some_wrapper.rb
module Tax
  module Rules
    module Xx
      class SomeWrapper < Base
        # Set explicitly, not derived from the class name: renaming a class
        # must not silently invalidate the rules households have stored.
        rule_id "xx_some_wrapper"
        label "Some Wrapper (gain, 5-year clock)"

        # Optional, and not documentation. Declaring the arithmetic as data
        # lets the rules screen show a household exactly what will run, and
        # test/models/tax/formula_test.rb runs the formula through
        # Rules::Composed and demands the same tax to the cent as #call. A
        # formula that drifts out of step with its rule fails the build.
        #
        # A rule too irregular to fit the shape leaves it out, and the page
        # then admits it cannot show the workings rather than showing a
        # simplified version that is not what ran.
        formula terms: [
          { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" },
          { base: "gain_over_paid_in", rate: "flat_tax",       condition: "immature" }
        ], maturity_years: 5

        def call(subject, on:, rates:, assumptions:)
          # Refuse when a fact you need is missing. Do NOT return zero: a
          # product with no answer reports nil, is excluded from the total, and
          # forces the total to be labelled incomplete.
          if subject.paid_in.nil?
            return refuse(
              subject,
              reason: "Tax here is levied on the gain over what was paid in, " \
                      "which Sure does not store.",
              needs: "the total paid in"
            )
          end

          # Ask the table for a rate by name. Never hard-code a figure -- that
          # is what makes a household's correction reach the arithmetic.
          social = rates.rate("social_charges", on)
          # ...
        end
      end
    end
  end
end
```

Three constraints on a rule, all load-bearing:

1. **It must not touch the database.** A rule is a pure function of
   `(Subject, date, RateTable, Assumptions) -> Result`. Everything it needs is
   on the `Subject`. That is what makes the engine testable without Rails, and
   what guarantees the module cannot change any of Sure's own numbers.
2. **It must refuse rather than guess.** `refuse(...)` with a `reason` and a
   `needs` is the correct answer when a fact is missing. Zero is a comfortable
   lie and the whole module exists to not tell it.
3. **It must ask `rates` for a rate by name**, never hard-code a figure.

One class per file — Zeitwerk. If you add a class, add it to
`TaxEngineTestHelper::ENGINE` too, in dependency order: the engine suites run
in a bare Ruby process (`ruby -Itest test/models/tax/engine_test.rb`) with no
Rails, no `ActiveSupport` and no `I18n`, and those are plain `require`s rather
than autoloads. Keep `I18n.t` out of engine classes; translation happens at the
view edge.

## Step 3: Map Sure's subtypes to your rules

One branch in `Tax::Registry.built_in`:

```ruby
def self.built_in(country)
  case country.to_s.upcase
  when "FR" then french_rules
  when "XX" then xx_rules
  else {}
  end
end
```

Key on Sure's own `(accountable_type, subtype)` pairs. This is the reason a
subtype added in a future Sure release surfaces as an explicit gap in
`Tax::Coverage` rather than being silently misfiled into a rule written for
something else. Map what you know and leave the rest uncovered — uncovered is a
reported state, not a failure.

Where the country taxes something the module will not model, map it to
`Rules::NotModelled.new(reason: "...")` with a reason a household can read. The
report prints it.

## Step 4: Offer the rules in the builder

`Tax::Catalogue.entries` is an allow-list, deliberately: `tax_custom_rules.kind`
is a user-writable string, and a user-writable string that gets `constantize`d
is a way to reach arbitrary classes. Add an id and a one-line description that
says what the rule does, not what it is called.

## Step 5: Wording

- `settings.tax_rates.sections.<your_section>` — the rates screen falls back to
  the section name humanised, so a missing entry degrades to "Social charges"
  rather than breaking. Add them anyway.
- `settings.tax_rates.hints.<your_section>` — optional, for a section whose
  meaning is not obvious from its name.
- `tax.rates.<your_rate>` in `config/locales/views/settings/tax_rules/en.yml` —
  how a rate is named inside a rule sentence ("31.4% flat tax on the gain over
  what was paid in"). Falls back to `Tax::Vocabulary.rate`, which humanises the
  name, so a missing entry reads awkwardly rather than breaking.

The module's locale files are its own, so that removing the module is a delete
rather than an unpick. Keep it that way, and add the same keys to `fr.yml`.

## Step 6: Test it

The engine suites run without Rails and without a database, which is the point:

```sh
ruby -Itest test/models/tax/engine_test.rb
ruby -Itest test/models/tax/rate_overlay_test.rb
```

The generic suites — `rate_overlay_test.rb` and `rate_edit_test.rb` — loop over
`dated_sections` rather than naming France's rates, so they will exercise your
file's sections the day it lands. What you owe on top is a suite for your own
rules, and specifically:

- an **equivalence test**, like the ones in `formula_test.rb`, run at a
  household rate that is *not* equal to your flat rate. At a rate that happens
  to match, a rule that multiplies the wrong base by the wrong rate still comes
  to the right total, and the test proves nothing.
- a test per **refusal**: for each fact your rule needs, assert that its absence
  produces `nil` and a reason rather than a number.

Then the Rails half:

```sh
bin/rails test test/models/tax test/controllers/settings test/controllers/tax_reports_controller_test.rb
```

## What a second country does not get you

Being honest about the boundary, because the report is:

- **One currency.** The report is drawn in the country's currency and refuses
  rather than guesses when it has no exchange rate.
- **One household rate.** A withdrawal large enough to push part of itself into
  a higher band is not modelled, and the report says so in its assumptions.
- **No residency logic.** The country comes from `families.country`. A household
  taxed by two countries is out of scope.

Each of those is stated on the report rather than hidden. If your country needs
one of them to be true before its numbers mean anything, the honest move is a
`NotModelled` rule with a reason — not a rule that computes anyway.
