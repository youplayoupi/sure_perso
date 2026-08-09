# frozen_string_literal: true

module Tax
  module Rules
    # Fully exempt from income tax and social charges.
    #
    # The zero this returns is a fact, not a fallback, which is the entire
    # difference between it and Tax::Rules::Unknown. Only register it where
    # exemption is genuinely a property of the product.
    class Exempt < Base
      rule_id "exempt"
      label "Exempt"

      def initialize(reason: "exempt from income tax and social charges")
        @reason = reason
      end

      def call(subject, on:, rates:, assumptions:)
        warnings = []

        ceiling = rates.ceiling(subject.product) if subject.product
        if ceiling && subject.value && subject.value > ceiling
          # Not an error: interest capitalises above the ceiling quite legally.
          warnings << "Balance exceeds the #{ceiling.to_i} deposit ceiling. That is " \
                      "normal once interest has capitalised, but a balance far above " \
                      "it may mean the product is misidentified."
        end

        result(
          subject,
          taxable_base: zero,
          tax: zero,
          basis: @reason,
          warnings: warnings
        )
      end
    end
  end
end
