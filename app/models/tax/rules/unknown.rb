# frozen_string_literal: true

module Tax
  module Rules
    # The fallback for any (accountable_type, subtype) pair with no rule.
    #
    # This is the most important class in the module, because it is the one
    # that runs when Sure adds a subtype nobody here has thought about. It
    # reports the gross value, refuses to name a tax, and forces the portfolio
    # total to be labelled incomplete. The alternative -- quietly taxing an
    # unrecognised product at some plausible default, or at zero -- would
    # produce a total that looks finished and is wrong.
    class Unknown < Base
      rule_id "unknown"
      label "No rule"

      def call(subject, on:, rates:, assumptions:)
        warnings = [
          "No tax rule for #{describe(subject)}. Gross is reported; the tax is " \
          "unknown and is excluded from the total."
        ]

        if subject.tax_treatment
          suggestion = Treatment.suggested_rule_id(subject.tax_treatment)
          warnings << "Sure classifies it as #{Treatment.label(subject.tax_treatment)}. " \
                      "That is a classification, not a rate, so it cannot produce a " \
                      "figure on its own" +
                      (suggestion ? " -- but it suggests the '#{suggestion}' rule would fit." : ".")
        end

        warnings << "If this product was added in a newer version of Sure, it needs a " \
                    "rule. One can be attached to it as a custom rule without changing " \
                    "any code."

        result(
          subject,
          taxable_base: nil,
          tax: nil,
          basis: "not modelled",
          warnings: warnings,
          modelled: false
        )
      end

      private
        def describe(subject)
          type = subject.accountable_type || "account"
          subject.subtype.nil? ? "#{type} with no subtype" : "#{type}/#{subject.subtype}"
        end
    end
  end
end
