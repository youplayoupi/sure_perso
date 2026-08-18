# frozen_string_literal: true

module Tax
  module Rules
    module Gb
      # A UK pension (SIPP, workplace pension) taken as a lump sum.
      #
      # A quarter of the pot can normally be taken tax-free; the remaining
      # three-quarters is taxed as income at the household's marginal rate.
      # So the taxable base is 75% of the whole balance -- not the gain, because
      # like a US 401(k) the contributions went in pre-tax and are taxed on the
      # way out.
      #
      # No formula is declared: "three-quarters of the balance at your rate" is
      # not one base times one rate from the vocabulary, and a rule too
      # irregular to fit the shape says so by leaving it out rather than
      # declaring a formula that would not reproduce the number.
      class Pension < Base
        rule_id "gb_pension"
        label "Pension lump sum (25% tax-free, your rate on the rest)"

        TAX_FREE_FRACTION = BigDecimal("0.25")

        # subject.value is guaranteed present here: Registry#apply returns an
        # unvalued result before any rule is called when it is nil.
        def call(subject, on:, rates:, assumptions:)
          rate    = assumptions.marginal_rate
          taxable = subject.value * (1 - TAX_FREE_FRACTION)
          tax     = taxable * rate

          warnings = [
            msg("gb_pension.note"),
            msg("deferred.lump_sum_caveat", rate: percent(rate), amount: amount(taxable))
          ]
          warnings << assumptions.marginal_rate_caveat if assumptions.marginal_rate_caveat

          result(
            subject,
            taxable_base: taxable,
            tax: cents(tax),
            basis: msg("gb_pension.basis", rate: percent(rate), amount: amount(taxable)),
            warnings: warnings,
            household_rate_income: taxable
          )
        end
      end
    end
  end
end
