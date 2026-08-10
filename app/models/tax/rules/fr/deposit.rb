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
                notes: [ Message.new("fr_deposit.note_interest_taxed_as_it_arises") ]

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
              basis: msg("exempt.basis"),
              warnings: ceiling_note(subject, rates)
            )
          end

          warnings = []
          warnings << if product == "taxable_savings"
            msg("fr_deposit.taxable_savings")
          elsif subject.subtype == "checking"
            msg("fr_deposit.checking")
          else
            msg("fr_deposit.unknown_product")
          end

          result(
            subject,
            taxable_base: zero,
            tax: zero,
            basis: msg("fr_deposit.basis_cash"),
            warnings: warnings + ceiling_note(subject, rates)
          )
        end

        private
          def ceiling_note(subject, rates)
            return [] if subject.product.nil?

            ceiling = rates.ceiling(subject.product)
            return [] if ceiling.nil? || subject.value.nil? || subject.value <= ceiling

            [
              msg("fr_deposit.exceeds_ceiling", ceiling: ceiling.to_i)
            ]
          end
      end
    end
  end
end
