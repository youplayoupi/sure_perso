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
          msg("unknown.no_rule", description: describe(subject))
        ]

        if subject.tax_treatment
          suggestion = Treatment.suggested_rule_id(subject.tax_treatment)
          suggestion_msg = suggestion ? msg("unknown.suggestion", rule: suggestion) : ""
          warnings << msg("unknown.treatment_is_classification",
                          treatment: Treatment.label(subject.tax_treatment),
                          suggestion: suggestion_msg)
        end

        warnings << msg("unknown.needs_custom_rule")

        result(
          subject,
          taxable_base: nil,
          tax: nil,
          basis: msg("base.cannot_be_computed"),
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
