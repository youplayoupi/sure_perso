# frozen_string_literal: true

module Tax
  # The bridge to Sure's existing `TaxTreatable` concern.
  #
  # Sure already classifies every account as :taxable, :tax_deferred,
  # :tax_exempt or :tax_advantaged. That classification carries no rate and no
  # rule -- there is no tax arithmetic anywhere in Sure -- but it is real
  # information, maintained upstream across 94 investment subtypes, and this
  # module should not duplicate or ignore it.
  #
  # It is used for three things:
  #
  #   1. Suggesting which rule to attach to a subtype that has none, so the
  #      coverage table tells you what to do rather than only what is missing.
  #   2. Auditing rules against it, so a disagreement between Sure's view and
  #      ours becomes a visible warning instead of a silent divergence.
  #   3. Describing gaps in the coverage table.
  #
  # It is deliberately NOT used to produce a number. The classification is
  # written from the perspective of the country the product belongs to: a Roth
  # IRA is :tax_exempt because it is exempt in the United States, which says
  # nothing whatsoever about how France would treat it in the hands of a French
  # resident. Turning :tax_exempt into "tax = 0" would be exactly the
  # comfortable lie this module exists to avoid.
  module Treatment
    KNOWN = %i[taxable tax_deferred tax_exempt tax_advantaged].freeze

    # Which rule most likely fits a product Sure has classified but we have no
    # rule for. A suggestion shown to a human, never applied automatically.
    SUGGESTED_RULE = {
      taxable: "fr_securities",
      tax_deferred: "fr_capital_and_gains",
      tax_advantaged: "fr_capital_and_gains",
      tax_exempt: "exempt"
    }.freeze

    class << self
      def suggested_rule_id(treatment)
        SUGGESTED_RULE[treatment&.to_sym]
      end

      # A Message, not a String, because it is dropped into the middle of two
      # sentences that get translated and would otherwise be the one English
      # word left standing in a French warning.
      def label(treatment)
        Message.new("treatments.#{treatment.nil? ? 'unclassified' : treatment}")
      end

      # Compare what Sure believes about an account with what the rule actually
      # did, and return warnings for the combinations that indicate a real
      # problem rather than a normal difference of scope.
      #
      # Kept narrow on purpose. Most mismatches are legitimate -- a PEA is
      # :tax_advantaged and still pays social charges -- and a check that cries
      # wolf on those would be turned off within a week.
      def audit(subject, result)
        treatment = subject.tax_treatment&.to_sym
        return [] if treatment.nil? || result.nil?

        warnings = []

        # This sentence used to name the jurisdiction, as `result.currency ||
        # "FR"`. Neither half of that was a country: a Result carries "EUR",
        # so the warning read "the EUR rule taxes it", and the fallback was a
        # country code standing in for a currency in a slot that wanted a
        # country. Nothing on a Subject or a Result knows which country's file
        # the rule came from, so the sentence no longer claims to. Saying less
        # is the only fix available that is not a plumbing change, and the
        # warning does not need the name to be actionable.
        if treatment == :tax_exempt && result.tax && result.tax.positive?
          warnings << Message.new("treatment.tax_exempt_but_taxed")
        end

        if %i[tax_deferred tax_advantaged].include?(treatment) && result.product == "cto"
          warnings << Message.new("treatment.deferred_or_advantaged_but_cto",
                                  treatment: label(treatment))
        end

        warnings
      end
    end
  end
end
