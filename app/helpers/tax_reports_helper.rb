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

  # Which figure the gain was measured against, as a half-line under the rule
  # name, or nil where the question does not arise.
  #
  # This is the one thing on the row a reader cannot reconstruct from anything
  # else on it. A PEA measured against the cost basis and a PEA measured
  # against declared versements print the same rule name, the same rate and the
  # same shape of figure, and mean different things by the number in the middle
  # -- one is what the household said, the other is a floor this module
  # substituted. The warning underneath already says so at length, but it is
  # behind a disclosure triangle by the time the row is otherwise fine, and by
  # then the substitution has become invisible rather than resolved.
  #
  # A whitelist rather than `t("....#{source}")`, because a symbol arriving
  # from a rule is data and interpolating data into an i18n key is how a page
  # renders `translation missing` in front of somebody's tax figures.
  SOURCE_KEYS = { paid_in: "paid_in", cost_basis: "cost_basis" }.freeze

  def tax_basis_source(result)
    key = SOURCE_KEYS[result.basis_source&.to_sym]
    return nil if key.nil?

    t("tax_reports.show.source.#{key}")
  end

  # What to call one declarable fact, and what to say about it, for the rule
  # that will actually read it.
  #
  # One hint per fact for the whole module was the earlier shape and it was
  # wrong in a way that is hard to notice: the opening-date hint explains the
  # five-year clock, which is the right sentence on a PEA and a false one on a
  # PER, where the date starts nothing and is asked for so the rule can tell a
  # 2019 contract from a 2024 one. A reader has no way to know the hint was
  # written for a different product, so they believe it.
  #
  # Hence a cascade rather than a table. `tax.rules.<rule_id>.facts.<fact>.hint`
  # if a rule has something of its own to say; the generic hint otherwise. The
  # fallback is the point: only the pairs that genuinely differ need writing,
  # and a rule added tomorrow inherits sentences that are already true rather
  # than rendering a missing key.
  #
  # In a helper rather than inline in the template because a fallback chain is
  # a thing worth testing, and ERB is not where that happens.
  def tax_fact_hint(fact, rule_id, currency: nil)
    tax_fact_string(fact, rule_id, :hint, currency: currency)
  end

  # The same cascade for the label, because a rule that reads a fact differently
  # usually calls it something different too: `paid_in` is *versements* on a PER
  # and *prix d'acquisition* on a CTO, and they are not synonyms.
  def tax_fact_label(fact, rule_id, currency: nil)
    tax_fact_string(fact, rule_id, :label, currency: currency)
  end

  # `currency:` is passed to every lookup and used by two of them. I18n ignores
  # an interpolation a string does not ask for, which is cheaper than keeping a
  # per-fact table of which arguments apply and remembering to update it.
  def tax_fact_string(fact, rule_id, part, currency: nil)
    generic = t("tax.profiles.fields.#{fact}.#{part}", currency: currency)
    return generic if rule_id.blank?

    t("tax.rules.#{rule_id}.facts.#{fact}.#{part}",
      currency: currency, default: generic)
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

  # Which of the ledger's seven columns survive a narrowing container, and the
  # order in which they come back.
  #
  # The mock is drawn on a desk-width canvas and says nothing about narrow. In
  # Sure the centre column is 475px whenever both the account list and the AI
  # panel are open, which is a perfectly ordinary way to have the app open, and
  # seven columns do not fit in it. Left alone the table simply overflowed:
  # `overflow-x-auto` meant it could be scrolled, but the reader saw Account,
  # Rule and half of Gross, with the net -- the number the page exists to print
  # -- off the right-hand edge and nothing on screen to suggest it was there.
  #
  # So the columns are dropped in reverse order of how much they are the point.
  # Account and Net always show, because the page is "what would I keep, per
  # account", and those two are that sentence. Tax comes back first, then the
  # gross it is a share of and the rule that produced it, then the working:
  # the base the rate was applied to, and the rate.
  #
  # Nothing is lost by dropping them, which is the reason this is preferable to
  # scrolling: the account cell still carries the row's keep/tax bar, its
  # status and its action, and the four cards above still carry the totals. A
  # reader who wants the working can close a sidebar or widen the window.
  #
  # Container breakpoints, not viewport ones. A viewport query cannot see a
  # sidebar open, which is the only thing that makes this column narrow.
  #
  # The breakpoints are one step below where the arithmetic suggests, because
  # the element carrying `container-type` is not the centre column but a
  # wrapper 80px inside it, and the query measures the wrapper. At a 1400px
  # window with both sidebars -- the case this whole table exists to survive --
  # the column is 595px and the container is 515px, so a threshold named for
  # 576px would have withheld the tax figure from precisely the layout it was
  # chosen for. Measured rather than reasoned about; see the note above each
  # value for what it buys.
  COLUMN_WIDTHS = {
    # `hidden` with a `table-cell` above the breakpoint rather than a `w-0`,
    # because a zero-width cell still takes its horizontal padding and still
    # gets read out by a screen reader as an empty cell in every row.
    #
    # No width hint until there is something to hint against. A quarter is the
    # right share of a seven-column table and the wrong share of a two-column
    # one: at 395px it held the account cell to a width that broke "PEA Bourse
    # Directe" over two lines while the net column sat on 183px of whitespace.
    # Unhinted, the browser gives the column the width its content needs.
    account: "@2xl:w-1/4",
    rule: "w-1/5 hidden @2xl:table-cell",
    gross: "hidden @2xl:table-cell",
    base: "hidden @5xl:table-cell",
    # First back, at the earliest breakpoint that fits a third column. Tax is
    # the one figure a reader cannot reconstruct from the other two.
    tax: "hidden @lg:table-cell",
    rate: "hidden @5xl:table-cell",
    net: ""
  }.freeze

  # Written once and read by the head, the body and the totals row, so a column
  # cannot be hidden in one of the three and left showing in the other two --
  # which in a table is not a cosmetic bug but a set of figures under the wrong
  # headings.
  def tax_column_class(column)
    COLUMN_WIDTHS.fetch(column)
  end

  # What share of a gross figure survives the tax on it, as a fraction, or nil
  # where the question cannot be answered.
  #
  # nil for a gross of zero rather than zero: an account worth nothing is not an
  # account that keeps nothing of what it is worth, and a bar drawn entirely red
  # over a closed Livret would say the second. nil for a nil tax for the same
  # reason -- a row this module declined to compute has no split to draw, and
  # drawing it all green would be the page quietly asserting that nothing is
  # owed on an account it just said it could not price.
  def tax_keep_share(gross, tax)
    return nil if gross.nil? || tax.nil? || gross <= 0

    ((gross - tax) / gross).clamp(0, 1)
  end

  # The two widths of a keep/tax bar, as CSS percentages, or nil for no bar.
  #
  # Full precision in the widths and one decimal in the legend beside them,
  # which is the mock's own choice and worth keeping: the bar is a picture and
  # should be drawn as accurately as the box allows, the legend is a sentence
  # and 87.0234% is not a thing anybody says.
  #
  # An inline width rather than a class, because the number is data. Tailwind
  # cannot have a utility per percentage and the arbitrary-value syntax is out
  # under this module's own rules; DS::Pill sets its dot the same way.
  #
  # Clamped upstream in `tax_keep_share`, so a custom rule that manages to tax
  # more than the account is worth draws a full red bar rather than two divs
  # that overflow their parent and push the row's chip off the card.
  def tax_split_widths(gross, tax)
    keep = tax_keep_share(gross, tax)
    return nil if keep.nil?

    [ format("%.4f%%", keep * 100), format("%.4f%%", (1 - keep) * 100) ]
  end

  # The tile that leads a row, as [icon, hex colour], taken from Sure's own
  # accountable classes so that a Crypto row on this page wears the same glyph
  # and the same hue it wears everywhere else in the app.
  #
  # Keyed on the accountable *type* rather than on the account, and that is the
  # privacy argument for it rather than a convenience: the account's name and
  # every figure beside it are blurred by the privacy toggle, and a tile derived
  # from the name -- an initial, which is what `accounts/_logo` renders -- would
  # spell the first letter of "Livret A" straight through the blur. The type is
  # already printed unblurred one line below.
  #
  # Through `Accountable.from_type` rather than `constantize`, which returns nil
  # for anything not in `Accountable::TYPES`. A `Tax::Result` carries its type
  # as a plain string across the engine boundary, and a page that constantizes
  # a string is one bad row away from raising in front of a tax figure.
  def tax_account_tile(result)
    klass = Accountable.from_type(result.accountable_type)
    return [ "landmark", nil ] if klass.nil?

    [ klass.icon, klass.color ]
  end

  # One row's effective rate. The same arithmetic Snapshot#effective_rate does
  # for the whole portfolio, per account, and it lives here rather than on
  # Tax::Result because it is a thing this page shows rather than a thing the
  # engine concluded -- no rule reasons about it, and adding it to the Result
  # would put a presentational figure through the engine's test suite.
  def tax_row_rate(result)
    return nil if result.gross.nil? || result.tax.nil? || result.gross.zero?

    result.tax / result.gross
  end

  # A row's warnings, sorted into what each of them asks of the reader, with
  # the page's one departure from the engine's own reading applied.
  #
  # The departure is `reviewed_at`, which until now was written on every save
  # and read by nothing -- which is why "à vérifier" never went away after you
  # had verified. A household that opened the form and saved it has answered
  # the question the form asked. If a gap is about a box that form actually
  # offered, it stops being a gap at that point and becomes a note: still true,
  # still printed, no longer demanding anything. Say it once and then be quiet.
  #
  # Two things are deliberately outside the demotion. A gap the account form
  # cannot close -- an unset household marginal rate, a disagreement with
  # Sure's own classification -- has no `asks_for` entry and so is never
  # quietened by a form that never asked. And a blocker is never demoted at
  # all: there is no figure, and no amount of having looked at the page makes
  # one appear.
  #
  # Done here rather than in Tax::Result because the engine's job is to keep
  # saying the true thing. How loudly to say it is a question about a page.
  def tax_warnings(result)
    result.warnings_by_severity.flat_map { |severity, list|
      list.map { |warning| [ tax_severity(result, severity, warning), warning ] }
    }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
  end

  def tax_severity(result, severity, warning)
    return severity unless severity == :gap && result.reviewed?
    return severity unless warning.respond_to?(:asks_for)
    return severity unless Tax::Profile::DECLARABLE.include?(warning.asks_for)

    :note
  end

  # Three states, and the third is the one this used to get wrong.
  #
  # It keyed off `warnings.any?`, so "interest on a Livret A is taxed as it
  # arises" -- a note that will never change and asks nobody for anything --
  # made a row look identical to a row genuinely missing a figure. Six rows out
  # of eight came out amber, which is the same as none of them being amber.
  #
  # Grey rather than amber for "not computed", against the comment this replaces
  # and the code that ignored it: amber says *you have something to fix*, and an
  # unmodelled product is this module's limitation rather than the reader's
  # mistake. Red would be worse again, for the same reason.
  #
  # Full i18n keys rather than the lazy `t(".x")` form, because lazy lookup
  # resolves against the template that happens to be rendering and a helper has
  # no business caring which one that is.
  # Returned as [label, tone, icon] for DS::Pill rather than as a string of
  # classes, which is what it used to be. The design's chip is a bordered soft
  # pill with a glyph, and DS::Pill in badge mode already is one -- tone
  # aliases, light/dark palettes, the border, the Lucide icon slot. Rebuilding
  # that out of `bg-success/10 text-success` would have been a second, worse
  # copy of a component this app already ships, and it would have missed dark
  # mode, which the hand-rolled version did.
  #
  # The glyphs carry the same three-way distinction as the tones, for readers
  # who cannot see the tones: a check, an hourglass, a dash. A dash rather than
  # a cross on the third, because a cross reads as rejection and nothing has
  # been rejected -- see the note about grey above.
  def tax_status_pill(result, warnings = tax_warnings(result))
    case tax_row_state(result, warnings)
    when :not_computed
      [ t("tax_reports.show.status.not_computed"), :neutral, "minus" ]
    when :incomplete
      [ t("tax_reports.show.status.incomplete"), :warning, "hourglass" ]
    else
      [ t("tax_reports.show.status.computed"), :success, "check" ]
    end
  end

  # The same three states as a bare symbol, for the controller to group on.
  #
  # Split out of the pill rather than reimplemented beside it, and that is the
  # whole reason it exists as a method. The table now sorts rows into blocks by
  # this and colours them by the pill; two copies of the same three conditions
  # would eventually disagree, and the failure would be a row filed under
  # "needs something" wearing a green badge -- a page arguing with itself in
  # front of somebody who came to it for an answer.
  #
  # Ordered by what the row asks of the reader, not by size or by name:
  # something is missing, then a figure that stands, then no figure at all. The
  # last block is last because it is this module's limitation rather than the
  # reader's to-do list, and putting it above accounts they could act on would
  # be leading with an apology.
  STATES = %i[incomplete computed not_computed].freeze

  def tax_row_state(result, warnings = tax_warnings(result))
    return :not_computed unless result.modelled?
    return :incomplete if warnings[:gap].present?

    :computed
  end

  # The link that belongs under a row's status, as [label, classes], or nil for
  # no link at all.
  #
  # Four answers, and the two in the middle are why this is a method rather
  # than a condition in the template. The report used to offer "Declare" on
  # every row with an account behind it -- including rows where a figure had
  # already been computed and stood, and rows where nothing a person could type
  # would change the outcome: an account whose subtype has no rule at all, or a
  # securities account missing a cost basis, which is derived from holdings and
  # collected by no form. An invitation to fill in a form that cannot help is
  # worse than no invitation, because it implies the missing number is one edit
  # away.
  #
  # So, in descending order of what the row is asking of the reader:
  #
  #   Declare   nothing was computed and a fact the form collects is why.
  #   Refine    a figure stands, and it was reached from a stand-in that a
  #             fact the form collects would replace. This is the state Part 4
  #             created: before it, the same account was a refusal wearing the
  #             first label, and the difference between the two is the whole
  #             argument for computing anyway.
  #   Adjust    a figure stands and nothing in particular is wrong with it.
  #   nothing   no form would help.
  #
  # Takes the already-demoted warnings rather than the raw ones, which is what
  # makes "Refine" stop being offered on a row the household has looked at and
  # left as it stands. Asking a second time for a box somebody deliberately
  # left empty is how a page teaches people to ignore it.
  def tax_profile_action(result, warnings = tax_warnings(result))
    return nil if result.account_id.blank?

    if (result.missing_facts & Tax::Profile::DECLARABLE).any?
      [ t("tax_reports.show.declare"), "text-link hover:underline" ]
    elsif tax_refinable_facts(warnings).any?
      [ t("tax_reports.show.refine"), "text-link hover:underline" ]
    elsif result.modelled?
      [ t("tax_reports.show.adjust"), "text-secondary hover:underline" ]
    end
  end

  # Facts a surviving gap asks for that this module's own form can collect.
  #
  # The mirror of `Result#missing_facts`, and the pair is the whole of this
  # part said in two lists: one is why there is no number, the other is why the
  # number there should not be taken at face value.
  #
  # Derived from the warnings rather than carried on the Result, because every
  # gap worth a box already names its box -- see Tax::Messages::ASKS_FOR -- and
  # a rule obliged to say it twice would eventually say it once. Gaps naming
  # nothing drop out here, which is right: the household's marginal rate lives
  # on a different screen and a disagreement with Sure's own classification is
  # fixed on the account, so neither is something this form could take.
  def tax_refinable_facts(warnings)
    Array(warnings[:gap])
      .filter_map { |warning| warning.asks_for if warning.respond_to?(:asks_for) }
      .uniq & Tax::Profile::DECLARABLE
  end
end
