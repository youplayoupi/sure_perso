# frozen_string_literal: true

# The rates screen's view vocabulary.
#
# Its own helper, like the rest of this module's files, so that taking the
# module out stays a delete rather than an unpick.
#
# Everything here is about one conversion and one comparison: the file stores
# 0.186 and the form says 18.6, and every box has to be able to say whether
# what it holds is what shipped or what the household typed.
module TaxRatesHelper
  # A stored fraction in the units the form asks for. 0.186 becomes "18.6".
  #
  # Exact, via BigDecimal, and that is not fussiness: 0.186 * 100 in floating
  # point is 18.599999999999998, which would refill the box with a number
  # nobody typed and then store it back as a correction the next time the page
  # was saved. Tax::RateEdit compares numerically and would still see through
  # it, but the household would be looking at a figure that is not their rate.
  def tax_percent_field(value)
    return nil if value.nil?

    decimal = tax_decimal(value)
    return value.to_s if decimal.nil?

    tax_trim((decimal * 100).to_s("F"))
  end

  # An amount as the form should hold it: no separators, no currency, no
  # trailing zeroes. 150000.0 out of the YAML parser becomes "150000".
  def tax_amount_field(value)
    return nil if value.nil?

    decimal = tax_decimal(value)
    return value.to_s if decimal.nil?

    tax_trim(decimal.to_s("F"))
  end

  # What the module ships, for the line under a box someone has changed.
  #
  # Rendered only when it differs from what the box holds, by the caller. A
  # "shipped: 18.6%" under every field on the page would be noise on the
  # overwhelming majority of rows, which are untouched.
  def tax_shipped_percent(value)
    return t("settings.tax_rates.none") if value.nil?

    "#{tax_percent_field(value)}%"
  end

  def tax_shipped_amount(value)
    return t("settings.tax_rates.none") if value.nil?

    tax_amount_field(value)
  end

  # Whether two figures off the two tables are the same number.
  #
  # Delegated to the engine rather than compared here, so that the view's idea
  # of "changed" and the storage layer's idea of "changed" cannot drift. If
  # they did, the page would mark a row as corrected that Tax::RateEdit had
  # decided not to store, or worse, the other way round.
  def tax_same_figure?(shipped, mine)
    Tax::RateEdit.same_figure?(shipped, mine)
  end

  # The dates a section has entries for, across both tables, in order.
  #
  # Taken from the merged table rather than the shipped one so that a schedule
  # the household added shows up with the rest, and sorted because the overlay
  # sorts on merge and a form that listed them in insertion order would jump
  # around after every save.
  def tax_effective_dates(table, section)
    table.entries_for(section).map { |entry| entry["effective_from"].to_s }.sort
  end

  def tax_entry(table, section, date)
    table.entries_for(section).find { |entry| entry["effective_from"].to_s == date.to_s }
  end

  # A product figure as the file holds it, unparsed.
  #
  # Not through RateTable#ceiling, which converts to BigDecimal and therefore
  # raises on the one input this page most needs to render: the value someone
  # just mistyped. The form wants what was typed so it can show it back beside
  # the error naming it; parsing belongs to the engine, which is downstream of
  # a save that will not happen.
  def tax_product_figure(table, name, key)
    table.product(name)[key.to_s]
  end

  # The headline flat tax -- the income part plus social charges -- or nil.
  #
  # Derived rather than stored, so that the two halves cannot drift apart, and
  # therefore uncomputable exactly when one of them is unreadable. That is the
  # error path of this very form, so it degrades to nil and the sentence
  # quoting it is dropped, rather than taking down the page that exists to fix
  # the problem.
  def tax_headline_flat_tax(table, on: Date.current)
    tax_percent_field(table.flat_tax(on))
  rescue Tax::Error, ArgumentError, TypeError
    nil
  end

  private
    def tax_decimal(value)
      return value if value.is_a?(BigDecimal)

      BigDecimal(value.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end

    # "18.600" -> "18.6", "150000.0" -> "150000". Only ever trailing zeroes
    # after a decimal point, so "1600" keeps its zeroes.
    def tax_trim(text)
      return text unless text.include?(".")

      text.sub(/\.?0+\z/, "")
    end
end
