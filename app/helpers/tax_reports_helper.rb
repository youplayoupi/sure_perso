# frozen_string_literal: true

module TaxReportsHelper
  # The nav entry, defined here rather than in ApplicationHelper so that
  # removing this module is a matter of deleting files rather than unpicking
  # edits from a shared one.
  #
  # Returns nil -- and the layout's `.compact` drops it -- when this module has
  # no rules for the family's country. A US household has no use for a page
  # that can only refuse to compute, and offering it would be worse than not
  # offering it.
  def tax_nav_item
    return nil unless Tax.supported?(Current.family&.country)

    {
      name: t("layouts.application.nav.tax"),
      path: tax_report_path,
      icon: "landmark",
      icon_custom: false,
      active: page_active?(tax_report_path)
    }
  end

  # The product list is read from the rate file rather than hard-coded, so
  # adding a product to config/tax/*.yml puts it in this dropdown with no Ruby
  # change. That is the same list Tax::Profile validates against, so the form
  # cannot offer a value the model would then reject.
  def product_choices(country = nil)
    rates = Tax.rate_table(country.presence || Current.family&.country.presence || Tax::DEFAULT_COUNTRY)
    rates.product_names.map { |name| [ rates.product_label(name), name ] }
  rescue Tax::Error
    []
  end

  # No default currency, deliberately. An earlier version defaulted to EUR,
  # which meant the headline total rendered with a euro sign over rows that
  # rendered with dollar signs -- the report contradicting itself in the one
  # place a reader looks first. A missing currency is now a caller's bug and
  # shows as such rather than as a plausible wrong symbol.
  def tax_money(amount, currency)
    return "—" if amount.nil?

    Money.new(amount, currency.presence || "EUR").format
  end

  def tax_percent(rate, precision: 1)
    return "—" if rate.nil?

    number_to_percentage(rate.to_d * 100, precision: precision)
  end

  # Amber for "we could not compute this", never red. Red reads as an error the
  # user caused; an unmodelled product is a limitation of this module, and the
  # colour should say so.
  def tax_status_pill(result)
    if !result.modelled?
      [ "Not computed", "bg-warning/10 text-warning" ]
    elsif result.warnings.any?
      [ "Check", "bg-warning/10 text-warning" ]
    else
      [ "Computed", "bg-success/10 text-success" ]
    end
  end
end
