# frozen_string_literal: true

module Tax
  # Effective-dated tax parameters for one country.
  #
  # Every lookup takes the valuation date and returns the value in force on
  # that date, so a 2025 valuation keeps the 17.2% social-charge rate after the
  # 2026 file has been updated to 18.6%. Rates never mutate retroactively.
  class RateTable
    attr_reader :country, :currency

    def self.load(country)
      new(read(country))
    end

    # The parsed file, before anyone's corrections are laid over it.
    #
    # Separate from `load` because Tax::RateOverlay merges hashes rather than
    # tables: a family with a corrected rate needs the shipped data to merge
    # onto, and getting it out of a built table would mean exposing innards
    # that are otherwise sealed by the `freeze` below.
    def self.read(country)
      path = Tax.config_dir.join("#{country.to_s.downcase}.yml")
      raise RateError, "no rate file for country #{country}" unless File.exist?(path)

      read_file(path)
    end

    def self.read_file(path)
      YAML.safe_load_file(path.to_s, permitted_classes: [ Date ])
    end

    # Split out so the rule engine can be exercised without Rails booted.
    def self.load_file(path)
      new(read_file(path))
    end

    def initialize(data)
      @data = data || {}
      @country = @data["country"].to_s
      @currency = @data["currency"].to_s
      freeze
    end

    # -- rates -------------------------------------------------------------

    # Every rate this file defines, by the name the file gives it, in force on
    # the valuation date.
    #
    # Nothing in here is named after a French tax. The country file declares
    # its own rates, this reads them back, and a formula term written by a
    # household refers to them by the same names -- so a second country is a
    # second YAML file and no change to the engine. The two French helpers
    # below exist only because the hand-written French rules are allowed to
    # know they are French; generic code goes through here.
    def rate(name, on)
      key = name.to_s
      return composite(key, on) if composite?(key)

      dec(effective(key, on).fetch("rate"))
    end

    # Whether a name a formula asked for is something this file defines. Used
    # to refuse an account whose rule names a rate the country does not have,
    # rather than treating the missing rate as zero.
    def rate?(name)
      key = name.to_s
      composite?(key) || dated_section?(key)
    end

    # The rate names a rule may use, for the rule builder's menu and for the
    # rates screen's list of things a household may correct.
    #
    # Discovered from the file rather than listed in Ruby: a section is any
    # top-level list of entries carrying an `effective_from` and a `rate`.
    # That is what stops a new section added to a country file from being
    # invisible to the two screens that exist to show the file.
    def rate_names
      (dated_section_names + composites.keys).uniq.sort
    end

    def dated_section_names
      RateOverlay.dated_sections(@data)
    end

    # Sections whose entries are something other than a single rate -- today
    # nothing, but the shape is what `entries_for` and the rates screen walk,
    # and a country whose file carries, say, a table of allowances would land
    # here rather than needing a new branch.
    def composites
      (@data["composites"] || {}).transform_values { |parts| Array(parts).map(&:to_s) }
    end

    # Two French names, spelled out because the hand-written French rules read
    # better for having them and because `flat_tax` is the one rate a reader
    # will look for by name. Both are `rate` underneath: correcting the social
    # charges on the rates screen moves these too, and there is no second copy
    # of the number to fall out of step.
    def social_charges(on) = rate("social_charges", on)

    def flat_tax(on) = rate("flat_tax", on)

    # The whole schedule for a dated section, not just the entry in force.
    #
    # Everything else on this class answers "what applies on this date", which
    # is the only question the engine ever has. The rates screen asks a
    # different one -- show me every entry, including the ones that have not
    # taken effect yet -- because a household correcting next year's rate has
    # to be able to see next year's rate.
    #
    # Deep-duplicated on the way out. `@data` is the memoised parse shared by
    # every family in the process, and handing a view a live reference to it
    # is how one household's edit ends up in another's report.
    def entries_for(section)
      deep_dup(Array(@data[section.to_s]))
    end

    # -- product metadata ---------------------------------------------------

    def product(name)
      products.fetch(name.to_s, {})
    end

    def product?(name)
      products.key?(name.to_s)
    end

    def product_label(name)
      product(name)["label"] || name.to_s
    end

    def product_names
      products.keys.sort
    end

    def maturity_years(name)
      product(name)["maturity_years"]
    end

    # Always a ceiling on cumulative payments in, never on current value.
    def ceiling(name)
      value = product(name)["ceiling"]
      value.nil? ? nil : dec(value)
    end

    def unmodelled_for(name)
      Array(@data["unmodelled"]).select { |u| Array(u["applies_to"]).include?(name.to_s) }
    end

    # The whole `unmodelled:` list, for the country page that enumerates what a
    # country taxes that this module deliberately does not.
    def unmodelled
      Array(@data["unmodelled"])
    end

    private
      def products
        @data["products"] || {}
      end

      # A composite is a rate the file does not state because it is the sum of
      # rates it does state. France's PFU is the only one today: 12.8% income
      # component plus social charges, 30% through 2025 and 31.4% from 2026.
      # Declaring it as a sum rather than a third number is what stops the
      # three from drifting apart when one of them is corrected.
      def composite?(name)
        composites.key?(name.to_s)
      end

      def composite(name, on)
        composites.fetch(name.to_s).sum(BigDecimal(0)) { |part| rate(part, on) }
      end

      def dated_section?(key)
        dated_section_names.include?(key.to_s)
      end

      def effective(key, on)
        entries = @data[key]
        raise RateError, "no '#{key}' block in the #{country} rate file" if entries.nil? || entries.empty?

        applicable = entries.select { |e| to_date(e["effective_from"]) <= on }
        if applicable.empty?
          earliest = entries.map { |e| to_date(e["effective_from"]) }.min
          raise RateError, "'#{key}' has no entry effective on #{on}; earliest is #{earliest}"
        end

        applicable.max_by { |e| to_date(e["effective_from"]) }
      end

      def to_date(value)
        value.is_a?(Date) ? value : Date.parse(value.to_s)
      end

      def dec(value)
        value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      end

      def deep_dup(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), out| out[k] = deep_dup(v) }
        when Array then value.map { |v| deep_dup(v) }
        else value
        end
      end
  end
end
