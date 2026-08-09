# frozen_string_literal: true

module Tax
  # A family's own mapping from one of its products to one of this module's
  # rules.
  #
  # The motivating case is PER: Sure has no subtype for it, so there is nothing
  # for a built-in rule to key on. Rather than inventing a private enum -- which
  # would go stale the day Sure ships `per` for real -- a family points whatever
  # subtype they are using at `fr_capital_and_gains` and gets the right answer
  # today. When Sure adds the subtype, the built-in rule takes over and the row
  # can be deleted with no change in output.
  #
  # A row selects a rule; it cannot define one. `kind` is looked up in
  # Tax::Catalogue, never constantized, so the worst a malicious or corrupted
  # row can do is choose a different rule from a list of five, all of which are
  # pure functions that cannot read or write the database.
  class CustomRule < ApplicationRecord
    self.table_name = "tax_custom_rules"

    belongs_to :family
    belongs_to :account, optional: true

    validates :kind, presence: true, inclusion: {
      in: ->(_) { Tax::Catalogue.kinds },
      message: "is not a rule this module offers"
    }
    validate :targets_exactly_one_thing
    validate :account_belongs_to_family

    scope :pinned, -> { where.not(account_id: nil) }
    scope :by_key, -> { where(account_id: nil) }

    # Registry consumes these four methods and nothing else. Keeping the
    # surface that small is what let the engine be tested against a fake.
    def to_rule
      Tax::Catalogue.build(kind, params)
    end

    def pinned? = account_id.present?

    def description
      Tax::Catalogue.description(kind)
    end

    # What this row covers, in words, for the coverage table.
    def target_label
      return account&.name || "a deleted account" if pinned?

      subtype.present? ? "#{accountable_type} / #{subtype}" : "every #{accountable_type}"
    end

    private
      # Either it is pinned to one account, or it is keyed on a type. Both at
      # once would be ambiguous, because the registry resolves them at
      # different priorities and the row would silently act as the pinned one.
      def targets_exactly_one_thing
        if account_id.present? && accountable_type.present?
          errors.add(
            :base,
            "A rule is either pinned to one account or applies to an account " \
            "type, not both. Two rows would be clearer than one ambiguous one."
          )
        elsif account_id.blank? && accountable_type.blank?
          errors.add(:base, "Choose either an account or an account type for this rule to apply to.")
        end
      end

      def account_belongs_to_family
        return if account.nil? || family_id.nil?
        return if account.family_id == family_id

        errors.add(:account, "does not belong to this family")
      end
  end
end
