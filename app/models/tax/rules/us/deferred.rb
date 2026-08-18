# frozen_string_literal: true

module Tax
  module Rules
    module Us
      # A tax-deferred US retirement wrapper (Traditional 401(k), 403(b),
      # 457(b), TSP, Traditional/SEP/SIMPLE IRA) on withdrawal.
      #
      # Contributions went in pre-tax and grew untaxed, so the *whole balance*
      # is taxed as ordinary income when it comes out -- not just the gain.
      # That is the one wrapper where taxing `full_value` rather than a gain is
      # correct, and it is why the deferred bill so often dwarfs a taxable
      # account's: there is no cost basis shielding any of it.
      #
      # "Ordinary income" means the household's own marginal rate, which is the
      # single number the module asks for. A single rate on the whole balance
      # is exact while the withdrawal stays in one band and understates it once
      # a large withdrawal climbs into the next -- stated, per the lump-sum
      # caveat, with the amount it applies to.
      #
      # Roth 401(k)/IRA are not here: their qualified withdrawals are tax-free
      # and the registry maps them to Rules::Exempt. An early-withdrawal 10%
      # penalty is a behaviour, not a property of holding the account, so it is
      # out of scope for a "what is it worth today" report.
      class Deferred < Base
        rule_id "us_deferred"
        label "Tax-deferred retirement account (your rate on the whole balance)"

        formula terms: [
          { base: "full_value", rate: "household_rate" }
        ], notes: [ Message.new("deferred.whole_balance_caveat") ]

        # subject.value is guaranteed present here: Registry#apply returns an
        # unvalued result before any rule is called when it is nil.
        def call(subject, on:, rates:, assumptions:)
          rate = assumptions.marginal_rate
          tax  = subject.value * rate

          warnings = [
            msg("deferred.whole_balance_caveat"),
            msg("deferred.lump_sum_caveat", rate: percent(rate), amount: amount(subject.value))
          ]
          warnings << assumptions.marginal_rate_caveat if assumptions.marginal_rate_caveat

          result(
            subject,
            taxable_base: subject.value,
            tax: cents(tax),
            basis: msg("deferred.basis", rate: percent(rate), amount: amount(subject.value)),
            warnings: warnings,
            household_rate_income: subject.value
          )
        end
      end
    end
  end
end
