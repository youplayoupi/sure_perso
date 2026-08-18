# frozen_string_literal: true

# Read-only after-tax reporting.
#
# Nothing in this namespace writes to an account, a holding, an entry or a
# balance. It reads what Sure already knows, adds the handful of facts Sure
# cannot know (declared per account in `tax_profiles`), and reports.
#
# Three design rules, in order of importance:
#
#   1. Unknown is never zero. A product with no rule reports `tax = nil`, is
#      excluded from the total, and forces the total to be labelled incomplete.
#      Returning zero for "we do not know" is how a tax tool tells a
#      comfortable lie.
#
#   2. Rules are keyed on Sure's own (accountable_type, subtype) pair. A
#      subtype added in a future Sure release therefore surfaces as an
#      explicitly uncovered product instead of falling into a rule written for
#      something else. `Tax::Coverage` enumerates the gap at runtime.
#
#   3. Rates are data (config/tax/*.yml, effective-dated). Rules are code.
#      Nothing in the YAML is constantized, so editing it can change a number
#      but can never execute anything.
#
module Tax
  class Error < StandardError; end
  class RateError < Error; end

  DEFAULT_COUNTRY = "FR"

  class << self
    # Rate tables are immutable once loaded, so caching them is safe. Call
    # `reset_rate_tables!` after editing a YAML file in development.
    def rate_table(country = DEFAULT_COUNTRY)
      @rate_tables ||= {}
      @rate_tables[country.to_s.upcase] ||= RateTable.new(rate_data(country))
    end

    # The shipped file as parsed, memoised, and shared by every family. Only
    # Tax::RateOverlay should want this, and only to merge onto -- which it
    # does into a copy, because a merge that wrote here would put one family's
    # corrections into everyone else's report.
    def rate_data(country = DEFAULT_COUNTRY)
      @rate_data ||= {}
      @rate_data[country.to_s.upcase] ||= RateTable.read(country)
    end

    # The rates as this family sees them: the shipped file, plus whatever they
    # have corrected.
    #
    # Deliberately not memoised. The cache above is keyed on country and lives
    # for the life of the process, which is right for a file on disk and wrong
    # for a row someone can edit and expect to see take effect. Callers that
    # need it more than once in a request hold onto it themselves -- see
    # TaxReportsController#rates.
    def rate_table_for(family, country = nil)
      country = (country.presence || family&.country.presence || DEFAULT_COUNTRY).to_s.upcase
      overrides = family && RateCorrection.overrides_for(family, country)

      return rate_table(country) if overrides.nil? || overrides.empty?

      RateTable.new(RateOverlay.apply(rate_data(country), overrides))
    end

    def reset_rate_tables!
      @rate_tables = {}
      @rate_data = {}
    end

    def config_dir
      Rails.root.join("config", "tax")
    end

    def supported_countries
      Dir.glob(config_dir.join("*.yml")).map { |f| File.basename(f, ".yml").upcase }.sort
    end

    def supported?(country)
      supported_countries.include?(country.to_s.upcase)
    end
  end
end
