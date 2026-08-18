# frozen_string_literal: true

module Tax
  module Rules
    # A product we know about, know is in scope, and have deliberately not
    # implemented. Distinct from Unknown: this is "we looked and decided not
    # to", not "we have never heard of it".
    #
    # Assurance vie is the standing example. Its taxation depends on the age of
    # the contract, the split between capital and gains, an annual allowance
    # and which of two regimes the payments fall under, none of which Sure
    # stores. Guessing would be worse than abstaining.
    class NotModelled < Base
      rule_id "not_modelled"
      label "Deliberately not modelled"

      # Read so Tax::CountryGuide can show *why* a wrapper is not modelled on
      # the country page, alongside where it is stated on a report.
      attr_reader :reason

      def initialize(reason:)
        @reason = reason
      end

      def call(subject, on:, rates:, assumptions:)
        result(
          subject,
          taxable_base: nil,
          tax: nil,
          basis: msg("base.cannot_be_computed"),
          warnings: [
            @reason,
            msg("not_modelled.excluded_from_total")
          ],
          modelled: false
        )
      end
    end
  end
end
