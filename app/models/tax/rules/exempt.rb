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

      # No terms. The same shape as Rules::Fr::Deposit and a different claim:
      # deposit says withdrawing your own cash is not an event, this says the
      # product is not taxed at all.
      formula terms: []

      # The default reason is the same sentence Rules::Fr::Deposit uses for a
      # Livret A, and deliberately the same key: two products exempt for the
      # same reason should not read as two slightly different exemptions
      # because two translators were handed the sentence twice.
      def initialize(reason: Message.new("exempt.basis"))
        @reason = reason
      end

      def call(subject, on:, rates:, assumptions:)
        warnings = []

        ceiling = rates.ceiling(subject.product) if subject.product
        if ceiling && subject.value && subject.value > ceiling
          # Not an error: interest capitalises above the ceiling quite legally.
          warnings << msg("exempt.exceeds_ceiling", ceiling: ceiling.to_i)
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
