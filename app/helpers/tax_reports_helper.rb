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

  # The (accountable_type, subtype) pairs this family actually holds, for
  # Tax::Coverage#partition_by.
  #
  # Scoped exactly as Tax::SubjectBuilder scopes the report -- visible, and no
  # liabilities -- so that "products you hold" on the settings page means the
  # same thing as "accounts on the report". A pair here is one whose rule
  # changes a number; a pair outside it is not.
  #
  # Read through `account.subtype` rather than plucked, which looks wasteful
  # and is not: `accounts.subtype` is a stale column, and the value Sure
  # actually uses lives on the delegated accountable. Plucking the column
  # returns nil for every account, which would put every product this family
  # holds on the wrong side of the split -- silently, since nil is itself a
  # real key for the types that have no subtypes. `includes` makes it one
  # query per accountable table, over an account list that is tens of rows.
  def tax_products_held(family)
    return Set.new if family.nil?

    family.accounts
          .visible
          .where.not(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
          .includes(:accountable)
          .map { |account| [ account.accountable_type, account.subtype ] }
          .to_set
  end

  # A rule's name and its one-line description, in the reader's language.
  #
  # Both live in Ruby -- on the rule class and in Tax::Catalogue -- and stay
  # there. The engine is required into a bare Ruby process by
  # test/models/tax/engine_test.rb, with nothing but bigdecimal, date and yaml
  # loaded, precisely so that a dependency on the framework cannot creep into
  # the arithmetic; reaching for `I18n.t` inside a rule class would end that
  # the day it was written.
  #
  # So the English is the engine's, and the translation happens here, at the
  # edge that already knows it is rendering a page. A locale with no entry for
  # a rule falls back to the engine's own name rather than to a bare `fr_pea`,
  # which also means a rule added tomorrow is legible before anybody
  # translates it.
  def tax_rule_label(rule_id, fallback = nil)
    return fallback if rule_id.blank?

    t("tax.rules.#{rule_id}.label", default: fallback.presence || rule_id)
  end

  def tax_rule_description(rule_id)
    return nil if rule_id.blank?

    fallback = Tax::Catalogue.description(rule_id)
    return nil if fallback.nil?

    t("tax.rules.#{rule_id}.description", default: fallback)
  end

  # A sentence the engine produced, in the reader's language.
  #
  # The engine names its sentences instead of spelling them out (see
  # Tax::Message) for the same reason the rule labels above are named: it loads
  # into a bare Ruby process and may not reach for I18n. So every warning,
  # every `basis` line and every clause on the rules screen arrives here as a
  # key and its values, and this is where a language is finally chosen.
  #
  # Three things can arrive.
  #
  # A Tax::Message is looked up under its own key with the engine's English as
  # the `default:`. A locale missing a key therefore gets a legible English
  # sentence rather than an identifier, which is what lets a message ship on
  # the day it is written and be translated on another one.
  #
  # A Tax::Message::List is joined here rather than by the engine, because the
  # joining word is itself a translation. A nil connector means commas only --
  # one clause narrowing the next, not a list of separate things.
  #
  # A String passes through untouched, and that is not laziness.
  # Tax::Rules::Composed carries the name and notes a family typed into their
  # own custom rule. Those are the household's own words about their own money,
  # and putting them through a translation table would be a category error.
  def tax_message(value)
    case value
    when Tax::Message::List then tax_message_list(value)
    when Tax::Message
      t(value.i18n_key, default: value.to_s, **tax_message_args(value.args))
    when ::Array then tax_message_list(Tax::Message::List.new(value))
    when nil then nil
    else value.to_s
    end
  end

  # Rendered depth-first, so a fact nested inside a refusal is already in the
  # reader's language before the sentence that contains it is assembled.
  def tax_message_args(args)
    args.transform_values do |value|
      case value
      when Tax::Message, Tax::Message::List, ::Array then tax_message(value)
      # The one kind of value the engine deliberately leaves raw. `l` knows the
      # reader's month names; the engine only knows English ones.
      when ::Date then l(value, format: :long)
      else value
      end
    end
  end

  def tax_message_list(list)
    parts = list.items.filter_map { |item| tax_message(item).presence }
    return "" if parts.empty?
    return parts.to_sentence(words_connector: ", ", last_word_connector: ", ") if list.connector.nil?

    word = t("tax.connectors.#{list.connector}",
             default: Tax::Vocabulary.connector(list.connector))

    parts.to_sentence(two_words_connector: " #{word} ", last_word_connector: " #{word} ")
  end

  # The product list is read from the rate file rather than hard-coded, so
  # adding a product to config/tax/*.yml puts it in this dropdown with no Ruby
  # change. That is the same list Tax::Profile validates against, so the form
  # cannot offer a value the model would then reject.
  # Through `rate_table_for`, so that a product a family added in their own
  # corrections is offered here too. Reading the shipped table instead would
  # let someone define a product and then be unable to select it.
  def product_choices(country = nil)
    rates = Tax.rate_table_for(Current.family, country)
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

  # Points for one polyline of the gross/net chart, in the fixed viewBox the
  # partial declares.
  #
  # Both lines are scaled against the *same* maximum -- passed in rather than
  # taken per-series -- because the whole point of the chart is the vertical
  # gap between them. Normalising each line to its own peak would draw two
  # lines that meet at the right-hand edge and claim the tax had vanished.
  def tax_chart_points(values, max:, width:, height:)
    return "" if values.blank? || max.nil? || max.zero?

    step = values.size > 1 ? width.to_f / (values.size - 1) : 0

    values.each_with_index.map { |value, index|
      y = height - ((value.to_d / max) * height)
      format("%.1f,%.1f", index * step, y.to_f.clamp(0, height))
    }.join(" ")
  end

  def tax_percent(rate, precision: 1)
    return "—" if rate.nil?

    number_to_percentage(rate.to_d * 100, precision: precision)
  end

  # Amber for "we could not compute this", never red. Red reads as an error the
  # user caused; an unmodelled product is a limitation of this module, and the
  # colour should say so.
  #
  # Full i18n keys rather than the lazy `t(".x")` form, because lazy lookup
  # resolves against the template that happens to be rendering and a helper has
  # no business caring which one that is.
  def tax_status_pill(result)
    if !result.modelled?
      [ t("tax_reports.show.status.not_computed"), "bg-warning/10 text-warning" ]
    elsif result.warnings.any?
      [ t("tax_reports.show.status.check"), "bg-warning/10 text-warning" ]
    else
      [ t("tax_reports.show.status.computed"), "bg-success/10 text-success" ]
    end
  end
end
