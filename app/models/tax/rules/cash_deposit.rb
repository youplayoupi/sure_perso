# frozen_string_literal: true

module Tax
  module Rules
    # Cash held in a bank account, for countries whose deposit rule needs none
    # of France's livret-specific wording.
    #
    # The report answers "what would I keep if I liquidated everything today",
    # and withdrawing your own cash is not a taxable event anywhere. So the
    # liquidation tax is zero -- but interest on a taxable account is taxed as
    # it arises, already paid, and outside this report. Saying "zero" without
    # saying which of those two zeroes it is would mislead, so the rule says.
    #
    # Rules::Fr::Deposit stays separate: it distinguishes a Livret A from an
    # ordinary livret, which is a French fact this generic rule has no business
    # carrying. A country whose deposits are genuinely undifferentiated uses
    # this one.
    class CashDeposit < Base
      rule_id "cash_deposit"
      label "Cash deposit"

      # No terms: nothing is taxed on liquidation. Everything else the rule
      # does is wording.
      formula terms: [],
              notes: [ Message.new("cash_deposit.note") ]

      def call(subject, on:, rates:, assumptions:)
        result(
          subject,
          taxable_base: zero,
          tax: zero,
          basis: msg("cash_deposit.basis"),
          warnings: [ msg("cash_deposit.note") ]
        )
      end
    end
  end
end
