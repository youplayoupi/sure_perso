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
      @rate_tables[country.to_s.upcase] ||= RateTable.load(country)
    end

    def reset_rate_tables!
      @rate_tables = {}
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
