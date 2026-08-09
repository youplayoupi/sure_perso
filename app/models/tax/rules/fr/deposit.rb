# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # Cash held in a bank account: current accounts, livrets, CDs, money
      # market accounts.
      #
      # This rule exists mostly to be careful about a frame. The report answers
      # "what would I keep if I liquidated everything today", and withdrawing
      # your own cash is not a taxable event whatever the account. So the
      # liquidation tax is zero for every deposit account -- but for a taxable
      # livret the *interest* is taxed as it arises, and that tax is real,
      # already paid, and outside this report entirely. Saying "zero" without
      # saying which of those two zeroes it is would be misleading.
      #
      # Sure files a Livret A, an LDDS and an ordinary taxable livret under the
      # same Depository/savings subtype, so the two cases cannot be told apart
      # from the subtype alone. That is why the wording depends on the declared
      # product rather than on the subtype.
      class Deposit < Base
        rule_id "fr_deposit"
        label "Deposit account"

        # No terms, which is how "nothing is taxed on liquidation" is written,
        # and is the whole of the arithmetic. Everything else this rule does is
        # wording -- telling the reader which of two different zeroes they are
        # looking at.
        formula terms: [],
                notes: [
                  "Interest on a taxable livret is taxed as it arises. That tax is real " \
                  "and already paid; it is outside a report about liquidating today."
                ]

        # Products whose interest is exempt from both income tax and social
        # charges, not merely untaxed on withdrawal.
        FULLY_EXEMPT = %w[livret_a ldds lep livret_jeune].freeze

        def call(subject, on:, rates:, assumptions:)
          product = subject.product

          if FULLY_EXEMPT.include?(product)
            return result(
              subject,
              taxable_base: zero,
              tax: zero,
              basis: "exempt from income tax and social charges",
              warnings: ceiling_note(subject, rates)
            )
          end

          warnings = []
          warnings << if product == "taxable_savings"
            "Interest on this account is taxable as it arises, at the flat tax or on " \
            "the progressive scale. That tax is not shown here: this report covers " \
            "liquidation only, and withdrawing a cash balance is not itself taxed."
          elsif subject.subtype == "checking"
            "A current account balance is untaxed on withdrawal. Any interest it pays " \
            "is taxed as it arises and is outside this report."
          else
            "Withdrawing a cash balance is not a taxable event, so the liquidation tax " \
            "is zero. If this is a taxable livret rather than a Livret A or LDDS, its " \
            "interest is taxed as it arises and is not shown here. Declare the product " \
            "on this account to remove the ambiguity."
          end

          result(
            subject,
            taxable_base: zero,
            tax: zero,
            basis: "no tax on liquidating a cash balance",
            warnings: warnings + ceiling_note(subject, rates)
          )
        end

        private
          def ceiling_note(subject, rates)
            return [] if subject.product.nil?

            ceiling = rates.ceiling(subject.product)
            return [] if ceiling.nil? || subject.value.nil? || subject.value <= ceiling

            [
              "Balance exceeds the #{ceiling.to_i} deposit ceiling. Interest capitalises " \
              "above the ceiling quite legally, but a balance well above it may mean the " \
              "product is misidentified."
            ]
          end
      end
    end
  end
end
