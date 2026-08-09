# frozen_string_literal: true

module Tax
  # A family's corrections to the shipped rate file.
  #
  # One row per family per country, holding a document that Tax::RateOverlay
  # lays over `config/tax/<country>.yml`. The merge, the vocabulary of what may
  # be corrected, and every validation live in the overlay, which is pure Ruby
  # and testable without Rails; this class is the storage and nothing else.
  #
  # Rates stay data. Nothing here can name a rule or a class, and the overlay
  # drops any section it does not recognise, so the worst a hand-written row
  # can do is fail to save.
  class RateCorrection < ApplicationRecord
    self.table_name = "tax_rate_corrections"

    belongs_to :family

    validates :country, presence: true, uniqueness: { scope: :family_id }
    validate :country_has_a_rate_file
    validate :corrections_are_readable

    normalizes :country, with: ->(value) { value.to_s.upcase }

    # The one method Tax.rate_table_for needs. Returns nil rather than an empty
    # hash when there is nothing to apply, so the caller can take the memoised
    # shipped table instead of rebuilding one per request for the overwhelming
    # majority of families who have corrected nothing.
    def self.overrides_for(family, country)
      return nil if family.nil?

      row = find_by(family_id: family.id, country: country.to_s.upcase)
      overrides = row&.overrides
      overrides.presence
    end

    def self.for(family, country)
      find_or_initialize_by(family: family, country: country.to_s.upcase)
    end

    def edited_sections = Tax::RateOverlay.edited_sections(overrides)

    def edited? = edited_sections.any?

    # The table as this family sees it, for previewing an edit before it is
    # trusted. Raises nothing on invalid data: callers should have validated.
    def to_rate_table
      Tax::RateTable.new(Tax::RateOverlay.apply(Tax.rate_data(country), overrides))
    end

    private
      def country_has_a_rate_file
        return if country.blank? || Tax.supported?(country)

        errors.add(:country, "has no rate file in this module yet")
      end

      # The overlay reports everything wrong at once, which is what a form with
      # a dozen inputs needs. Blocking the save matters more here than it does
      # for a profile: a bad rate does not refuse to compute, it computes
      # confidently and wrongly, and there is no run-time refusal downstream to
      # catch it the way Rules::Composed catches a bad formula.
      def corrections_are_readable
        Tax::RateOverlay.errors(overrides).each { |message| errors.add(:overrides, message) }
      end
  end
end
