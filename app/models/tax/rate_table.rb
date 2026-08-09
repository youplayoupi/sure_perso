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
      path = Tax.config_dir.join("#{country.to_s.downcase}.yml")
      raise RateError, "no rate file for country #{country}" unless File.exist?(path)

      load_file(path)
    end

    # Split out so the rule engine can be exercised without Rails booted.
    def self.load_file(path)
      new(YAML.safe_load_file(path.to_s, permitted_classes: [ Date ]))
    end

    def initialize(data)
      @data = data || {}
      @country = @data["country"].to_s
      @currency = @data["currency"].to_s
      freeze
    end

    # -- rates -------------------------------------------------------------

    def social_charges(on)
      dec(effective("social_charges", on).fetch("rate"))
    end

    def flat_tax_income_component(on)
      dec(effective("flat_tax_income_component", on).fetch("rate"))
    end

    # PFU: income component plus social charges. 30% through 2025, 31.4% from
    # 2026. Derived rather than stored so the two can never drift apart.
    def flat_tax(on)
      flat_tax_income_component(on) + social_charges(on)
    end

    # [[upper_bound_or_nil, rate], ...]
    def brackets(on)
      effective("income_tax_brackets", on).fetch("brackets").map do |b|
        [ b["upto"].nil? ? nil : dec(b["upto"]), dec(b["rate"]) ]
      end
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

    # -- progressive income tax --------------------------------------------

    # Tax on `taxable` under the quotient familial: divide by parts, tax each
    # part through the brackets, multiply back.
    def income_tax(taxable, on:, parts: BigDecimal(1))
      return BigDecimal(0) if taxable <= 0

      per_part = taxable / parts
      total = BigDecimal(0)
      lower = BigDecimal(0)

      brackets(on).each do |upto, rate|
        if upto.nil?
          total += [ BigDecimal(0), per_part - lower ].max * rate
          break
        end

        span = [ per_part, upto ].min - lower
        total += span * rate if span > 0
        break if per_part <= upto

        lower = upto
      end

      total * parts
    end

    # The extra tax caused by stacking `additional` on top of `other_income`.
    #
    # This is the only honest way to tax a lump sum: a EUR 51k withdrawal can
    # push the taxpayer through two brackets, so applying a single flat
    # marginal rate to the whole amount is wrong in both directions depending
    # on where they started.
    def marginal_income_tax(additional, other_income:, on:, parts: BigDecimal(1))
      return BigDecimal(0) if additional <= 0

      before = income_tax(other_income, on: on, parts: parts)
      after  = income_tax(other_income + additional, on: on, parts: parts)
      after - before
    end

    private
      def products
        @data["products"] || {}
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
  end
end
