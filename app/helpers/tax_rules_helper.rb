# frozen_string_literal: true

# The rule library's view vocabulary.
#
# A separate helper from TaxReportsHelper because the two answer different
# questions -- that one renders a computed report, this one renders and edits
# the rules behind it -- and because a module that comes out by deleting files
# should not have one helper that half the app's pages depend on.
module TaxRulesHelper
  # A formula, ready to render, resolved against the rates this family is
  # actually on.
  #
  # `rate_table_for` rather than `rate_table`, so that a household that has
  # corrected a rate sees its own figure here and not the shipped one. A page
  # explaining what a rule does that quoted a rate the rule will not use would
  # be worse than a page that quoted no rate at all.
  def tax_formula_presenter(formula, product: nil, on: Date.current)
    Tax::FormulaPresenter.new(
      formula,
      rates: tax_rates_for_current_family,
      on: on,
      product: product
    )
  end

  def tax_rates_for_current_family
    Tax.rate_table_for(Current.family)
  rescue Tax::Error
    nil
  end

  # The three closed lists a term is assembled from, as select options.
  #
  # Each is built from the engine's own constant rather than from a list
  # written out here, so a base or a rate added to Tax::Formula appears in the
  # form with no view change -- and, more to the point, a form can never offer
  # a value the validator would then reject.
  def tax_base_choices
    Tax::Formula::BASES.keys.map do |base|
      [ t("tax.bases.#{base}", default: Tax::Vocabulary.base(base)), base ]
    end
  end

  def tax_rate_choices
    Tax::Formula::RATES.map do |rate|
      [ t("tax.rates.#{rate}", default: Tax::Vocabulary.rate(rate)), rate ]
    end
  end

  def tax_condition_choices
    Tax::Formula::CONDITIONS.map do |condition|
      [ t("settings.tax_rules.conditions.#{condition}"), condition ]
    end
  end

  # Where a rule applies, as one grouped select.
  #
  # Three groups, in the order someone actually chooses from them: this
  # family's accounts, then the products this family holds, then the rest of
  # Sure's world catalogue. A flat list would file the PEA between Kisan Vikas
  # Patra and Riester-Rente -- eighty-odd wrappers across a dozen countries,
  # with the one that matters somewhere in the middle.
  def tax_target_choices(accounts, held_products, other_products = [])
    [
      [ t("settings.tax_rules.target.accounts"),
        accounts.map { |a| [ a.name, "account:#{a.id}" ] } ],
      [ t("settings.tax_rules.target.products"), product_options(held_products) ],
      [ t("settings.tax_rules.target.other_products"), product_options(other_products) ]
    ].reject { |_group, options| options.empty? }
  end

  def product_options(entries)
    Array(entries).map { |e| [ e.label, "product:#{e.accountable_type}|#{e.subtype}" ] }
  end

  def tax_target_value(rule)
    return nil if rule.nil?
    return "account:#{rule.account_id}" if rule.account_id.present?
    return nil if rule.accountable_type.blank?

    "product:#{rule.accountable_type}|#{rule.subtype}"
  end

  # A stored fraction, back in the units the form asks for. 0.075 becomes 7.5.
  #
  # Trailing zeroes are stripped here and not in FormulaPresenter#percentage,
  # because these two are doing different jobs: that one lines a column of
  # rates up for reading, this one refills a box someone typed in, and "7.50"
  # in a text field they are about to edit is noise.
  def tax_literal_percent(term)
    return nil if term.nil? || term.literal_rate.nil?

    (term.literal_rate * 100).to_s("F").sub(/\.0+\z/, "")
  end
end
