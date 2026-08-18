# frozen_string_literal: true

module Tax
  # Everything the engine can say to a reader, in one place, in English.
  #
  # This is the list a translator is handed. That is the whole reason it is a
  # file rather than fifty string literals sitting where they are raised --
  # which is where they were, and read better there, beside the arithmetic they
  # describe. The trade is deliberate: prose that is easy to find beats prose
  # that is easy to happen upon, once the question stops being "why does this
  # rule say that" and becomes "what does this module say, and has anybody
  # translated it".
  #
  # The `why` did not move. It stayed in the rules, as comments, next to the
  # code it explains. What moved is the sentence the reader sees.
  #
  # Plain Ruby, deliberately: no I18n, no ActiveSupport. The engine loads into
  # a bare process (see test/models/tax/engine_test.rb) and this file loads with
  # it, so `to_s` on any Message works with nothing but the standard library.
  #
  # Adding a message means adding a key here. test/models/tax/messages_test.rb
  # walks this hash against the locale files, so a key added without a French
  # translation is a failing build rather than an English sentence that turns up
  # on a French report six months later.
  module Messages
    # Placeholders are `%{name}`, which is what both Ruby's `String#%` and I18n
    # expect, so one template serves the fallback and the translation.
    #
    # An array value is joined before interpolation -- by Vocabulary.to_sentence
    # here, and by Rails' locale-aware Array#to_sentence at the view edge, so
    # that a French reader gets "et" rather than "and" without the engine ever
    # knowing there was a choice.
    #
    # No template contains a literal percent sign. Ruby's `String#%` reads `%%`
    # as an escaped one and I18n does not touch it at all, so a template with
    # `%%` in it renders differently depending on which of the two got to it --
    # English and French disagreeing about a tax rate, for no reason a reader
    # could ever diagnose. Percentages therefore arrive already formatted, sign
    # included, from Rules::Base#percent.
    TEXTS = {
      # --- Shared refusal scaffolding -------------------------------------
      #
      # Raised by Rules::Base rather than by any one rule, so that every
      # refusal in the module ends the same way and a reader learns the shape
      # once.
      "base.declare" =>
        "Declare %{needs} for this account to compute it.",
      "base.cannot_be_computed" =>
        "cannot be computed",
      "base.cost_basis_footnote" =>
        "For reference only: cost basis is %{cost_basis} giving a gain of %{gain}. " \
        "Cost basis is not the same as money paid in and is not used here.",

      # --- The rules screen, via Tax::FormulaPresenter ---------------------
      #
      # These describe a rule rather than an account, and none of them names a
      # sum of money: the presenter resolves rates and thresholds and refuses
      # to guess at amounts. Word order is the reason each clause is its own
      # key -- English leads with the rate and trails the condition behind a
      # comma, and nothing obliges another language to do either.
      "formula.nothing_taxed" =>
        "Nothing is taxed when this account is liquidated.",
      "formula.headline" =>
        "Tax is %{terms}.",
      "formula.needs" =>
        "Needs %{facts}.",
      "formula.rate_with_percent" =>
        "%{percent} %{rate}",
      "formula.head_with_percent" =>
        "%{rate} on %{base}",
      "formula.head_named_rate" =>
        "%{rate} on %{base}",
      # The rate is named but carries no figure on this date -- the country's
      # file does not reach back this far, typically. The base leads instead,
      # because there is no number to lead with.
      "formula.head_unresolved_rate" =>
        "%{base} at the %{rate} rate",
      "formula.condition_mature" =>
        "once the account is %{clock}",
      "formula.condition_immature" =>
        "while the account is under %{years} years old",
      "formula.condition_immature_unknown_clock" =>
        "while the account is under the maturity period",
      "formula.clock_years" =>
        "%{years} years old",
      "formula.clock_unknown" =>
        "mature",
      "formula.window_between" =>
        "for accounts opened between %{from} and %{until}",
      "formula.window_from" =>
        "for accounts opened on or after %{from}",
      "formula.window_until" =>
        "for accounts opened on or before %{until}",
      "formula.window_unreadable" =>
        "for accounts whose opening window cannot be read",

      # --- Ordinary securities account (CTO) ------------------------------
      "fr_securities.no_cost_basis" =>
        "The capital gain is the current value minus the acquisition cost of the " \
        "securities, and no cost basis is recorded on the holdings in this account.",
      "fr_securities.latent_loss" =>
        "Latent loss of %{loss}. Realised losses offset gains for ten years, which " \
        "is not modelled.",
      "fr_securities.declared_cost" =>
        "Using the declared figure as the acquisition cost. For a securities account " \
        "the correct base is what the holdings cost, not the cash paid into the " \
        "account -- check the declared value is the former.",
      "fr_securities.flat_tax_assumed" =>
        "The flat tax is assumed. Electing the progressive scale instead can beat it " \
        "below roughly a %{rate} effective rate and is not modelled.",
      "fr_securities.basis" =>
        "flat tax %{rate} on the capital gain (cost %{cost})",

      # --- PEA (gain net, 5-year clock) ----------
      "fr_pea.no_paid_in" =>
        "PEA tax is levied on the gain net, which is the current value minus the total paid in. Neither that figure nor a cost basis for the holdings is available, so there is nothing to measure a gain against.",
      "fr_pea.computed_from_cost_basis" =>
        "The total paid in is not declared, so the gain is measured against what the holdings cost (%{cost_basis}). Selling and rebuying inside the plan raises that figure while the payments in do not, so it is a floor and the tax below is the least this plan could owe. Declare the total paid in to replace it.",
      "fr_pea.loss" =>
        "Value is %{loss} below the amount paid in. A loss is not taxed. A realised loss on closing the plan may be offsettable, which is not modelled.",
      "fr_pea.no_opening_date" =>
        "The opening date is not declared, so the %{maturity}-year clock cannot be checked. Assuming the plan is mature. If it is not, the tax would be %{immature_tax} instead of %{mature_tax}.",
      # The same assumption as the sentence above, said to a reader who has an
      # opening date on the account in Sure and would otherwise read "not
      # declared" as the module failing to look. It looked. Sure's date is the
      # first day this account is known to have held money, and an account that
      # already held money on a date is older than that date -- so it bounds the
      # age from below and cannot settle a clock the bound falls short of.
      # Naming the date is what makes that legible, and what tells the reader
      # the bound is wrong rather than the arithmetic.
      "fr_pea.opening_date_floor_only" =>
        "Sure has this account holding money on %{since}, so it was opened on or before then -- a floor, not an opening date, and short of the %{maturity} years the clock needs. Assuming the plan is mature. If it is not, the tax would be %{immature_tax} instead of %{mature_tax}. Correct the account's opening balance in Sure, or declare the date here.",
      "fr_pea.mature_by_lower_bound" =>
        "The opening date is not declared, but this account already held money on %{since}, which is more than %{maturity} years ago. The clock has run whatever the exact date was.",
      "fr_pea.immature" =>
        "The plan is %{age} years old, under %{maturity}. Any withdrawal closes it and the whole gain takes the full rate.",
      "fr_pea.exceeds_ceiling" =>
        "Payments in of %{paid_in} exceed the %{ceiling} ceiling for this plan.",
      "fr_pea.taux_historiques" =>
        "Opened between 2013 and 2017, so part of the gain may qualify for the social-charge rates in force when it accrued. Not modelled, so the tax here may be overstated.",
      "fr_pea.basis_mature" =>
        "social charges %{rate} on the gain net (plan mature, income tax exempt)",
      "fr_pea.basis_immature" =>
        "flat tax %{rate} on the gain net (plan under %{maturity} years)",

      # --- Deposit accounts ----------
      "fr_deposit.taxable_savings" =>
        "Interest on this account is taxable as it arises, at the flat tax or on the progressive scale. That tax is not shown here: this report covers liquidation only, and withdrawing a cash balance is not itself taxed.",
      "fr_deposit.checking" =>
        "A current account balance is untaxed on withdrawal. Any interest it pays is taxed as it arises and is outside this report.",
      "fr_deposit.unknown_product" =>
        "Withdrawing a cash balance is not a taxable event, so the liquidation tax is zero. If this is a taxable livret rather than a Livret A or LDDS, its interest is taxed as it arises and is not shown here. Declare the product on this account to remove the ambiguity.",
      "fr_deposit.exceeds_ceiling" =>
        "Balance exceeds the %{ceiling} deposit ceiling. Interest capitalises above the ceiling quite legally, but a balance well above it may mean the product is misidentified.",
      "fr_deposit.basis_cash" =>
        "no tax on liquidating a cash balance",
      "fr_deposit.note_interest_taxed_as_it_arises" =>
        "Interest on a taxable livret is taxed as it arises. That tax is real and already paid; it is outside a report about liquidating today.",

      # --- Capital and gains (lump sum) ----------
      "fr_capital_and_gains.no_paid_in" =>
        "This wrapper splits into payments in and growth, taxed under different regimes. Neither the amount paid in nor a cost basis for the holdings is available, so there is nothing to split.",
      "fr_capital_and_gains.computed_from_cost_basis" =>
        "The total paid in is not declared, so what the holdings cost (%{cost_basis}) stands in for it -- in the capital as well as in the growth, so that the two together still come to the whole value. It is the larger of the two figures whenever this wrapper has gained, so more of the value is taxed at your marginal rate than should be and the tax below is the most this wrapper could owe. Declare the total paid in to replace it.",
      "fr_capital_and_gains.no_deducted" =>
        "The deducted portion is not declared, so all payments in are assumed to have been deducted. That is the higher-tax assumption. Declare it if some payments were made without taking the deduction.",
      "fr_capital_and_gains.deducted_exceeds_total" =>
        "The declared deducted portion (%{deducted}) exceeds the total paid in (%{paid_in}). Capped at the total; one of the two figures is wrong.",
      "fr_capital_and_gains.lump_sum_caveat" =>
        "The capital is taxed at your marginal rate of %{rate} throughout. A lump sum of %{amount} taken in one year may push part of itself into a higher band, which this does not model -- the real bill would then be larger, never smaller.",
      "fr_capital_and_gains.non_deducted_untaxed" =>
        "%{amount} of non-deducted payments in comes back untaxed.",
      "fr_capital_and_gains.whole_wrapper_lump_sum" =>
        "Assumes the whole wrapper is taken as a lump sum in a single tax year. Spreading withdrawals lowers the bill and is not modelled.",
      "fr_capital_and_gains.mixed_election_not_modelled" =>
        "Assumes you elected the progressive scale over the flat tax. That election covers all of your investment income for the year, so it cannot apply to this account alone: if another account here is on the flat tax, one of the two is wrong.",
      # "household rate" is in the template on purpose. The basis column is the
      # one line that says which of the two rates did the work, and a bare
      # percentage there reads as a published rate rather than as the figure
      # the household typed in -- which is the distinction the rest of the
      # module spends its warnings preserving.
      "fr_capital_and_gains.basis" =>
        "%{rate} household rate on %{amount} of deducted payments in (%{capital_tax}) " \
        "plus %{gains_rate} on %{gains} of growth (%{gains_tax})",

      # --- Composed rule (custom) ----------
      "composed.invalid_formula" =>
        "The custom rule set for this account does not describe a valid calculation: %{problems}. Nothing is assumed in its place -- fix the rule and this account will compute.",
      "composed.missing_facts" =>
        "This rule taxes %{bases}, which needs %{facts}. That is not recorded for this account.",
      "composed.no_deducted_portion" =>
        "The deducted portion of the payments in is not declared, so all of them are assumed to have been deducted. That is the higher-tax assumption.",
      "composed.deducted_exceeds_total" =>
        "The declared deducted portion (%{declared}) is more than the total paid in (%{paid_in}). Capped at the total; one of the two figures is wrong.",
      "composed.no_opening_date" =>
        "No opening date is declared, so the %{years}-year clock cannot be checked. Treated as mature, which gives %{mature_tax}; if it is not, the tax would be %{young_tax}.",
      # See fr_pea.opening_date_floor_only. Kept in step with the built-in rule
      # on purpose: a household's own rule with a clock should say the same
      # thing about the same facts as the shipped one, or the rules screen is
      # quietly offering something else.
      "composed.opening_date_floor_only" =>
        "Sure has this account holding money on %{since}, so it was opened on or before then -- a floor, not an opening date, and short of the %{years} years the clock needs. Treated as mature, which gives %{mature_tax}; if it is not, the tax would be %{young_tax}. Correct the account's opening balance in Sure, or declare the date here.",
      "composed.known_since" =>
        "No opening date is declared, but this account already held money on %{since}, which is more than %{years} years ago. The clock has run whatever the exact date was.",
      "composed.immature" =>
        "This wrapper is %{age} years old, under the %{years} it needs, so the terms that depend on the clock are taxed at the pre-maturity rate.",
      "composed.not_taxed_on_liquidation" =>
        "not taxed on liquidation",
      # Each line of the calculation, named rather than left as a bare
      # percentage: the reader has to be able to tell which line is theirs to
      # correct, and "30.0% on 40000" beside "12.8% on 5000" gives them no way
      # to. The wrapper below looks like a template that does nothing, and
      # nearly is -- it exists so a language that wants a lead-in, or different
      # punctuation between the addends, has somewhere to put it.
      "composed.term" =>
        "%{rate} on %{amount} (%{tax})",
      "composed.term_household_rate" =>
        "%{rate} household rate on %{amount} (%{tax})",
      "composed.basis" =>
        "%{terms}",

      # --- Unknown rule (catch-all) ----------
      "unknown.no_rule" =>
        "No tax rule for %{description}. Gross is reported; the tax is unknown and is excluded from the total.",
      "unknown.treatment_is_classification" =>
        "Sure classifies it as %{treatment}. That is a classification, not a rate, so it cannot produce a figure on its own%{suggestion}.",
      "unknown.suggestion" =>
        " -- but it suggests the '%{rule}' rule would fit.",
      "unknown.needs_custom_rule" =>
        "If this product was added in a newer version of Sure, it needs a rule. One can be attached to it as a custom rule without changing any code.",

      # --- Exempt rule ----------
      #
      # `exempt.basis` is also what Rules::Fr::Deposit prints for a Livret A.
      # One key, because it is one claim.
      "exempt.basis" =>
        "exempt from income tax and social charges",
      "exempt.exceeds_ceiling" =>
        "Balance exceeds the %{ceiling} deposit ceiling. That is normal once interest has capitalised, but a balance far above it may mean the product is misidentified.",

      # --- Treatment audits ----------
      "treatment.tax_exempt_but_taxed" =>
        "Sure classifies this account as tax exempt, but the rule that ran taxes it. Exemption is granted by the country the product belongs to, and does not transfer. Check which is right before relying on either.",
      "treatment.deferred_or_advantaged_but_cto" =>
        "Sure classifies this account as %{treatment}, but it is being taxed as an ordinary securities account. If the wrapper really is tax-advantaged, it needs its own rule.",

      # --- Registry (unvalued accounts) ----------
      "registry.no_value" =>
        "This account's value could not be expressed in %{currency}, so it is excluded from the totals entirely -- not counted as zero.",

      # --- Not modelled rules ----------
      #
      # One key per product rather than one parameterised sentence, because
      # what makes each of these unmodellable is different and the reader is
      # owed the specific reason. They are registered in Tax::Registry.
      "not_modelled.excluded_from_total" =>
        "Gross is reported; the tax is unknown and is excluded from the total.",
      "not_modelled.assurance_vie" =>
        "Assurance vie taxation depends on the age of the contract, the split between capital and gains, an annual allowance and which of two regimes the payments fall under. Sure stores none of that.",
      "not_modelled.crypto" =>
        "French crypto gains are computed on a portfolio-wide formula that prorates total acquisition cost across the whole holding, not per-asset. That is a different calculation from securities and is not implemented.",
      "not_modelled.property" =>
        "Property gains depend on whether it is your main home, and otherwise on allowances that taper with how long you have owned it. Not modelled.",

      # --- Assumptions ----------
      "assumptions.marginal_rate_caveat" =>
        "No household marginal rate has been set, so %{rate} is assumed for the part taxed as income. That is a guess, not your rate: set it under Taxes and this figure changes.",

      # --- US / UK / IN capital-gains rules (see app/models/tax/rules/{us,gb,in}) -
      "cash_deposit.basis" =>
        "cash; withdrawing the balance is not itself a taxable event",
      "cash_deposit.note" =>
        "Interest on a taxable account is taxed as it arises, which is already paid and outside this report.",

      "securities_gain.basis" =>
        "%{rate} on the gain of %{gain} over a cost basis of %{cost}.",
      "securities_gain.no_cost_basis" =>
        "This account is taxed on the gain over what the holdings cost, which Sure has not recorded.",
      "securities_gain.latent_loss" =>
        "This account shows a latent loss of %{loss}, so no gain is taxed today.",

      "us_long_term.rate_assumed" =>
        "The %{rate} long-term rate is assumed. Assets held a year or less are taxed as ordinary income; Sure does not record holding periods.",
      "us_long_term.bracket" =>
        "The US long-term rate is 0, 15 or 20 percent depending on income; the middle band is assumed. Correct it under Taxes if you sit in another band.",
      "us_niit.note" =>
        "High earners may owe an additional net investment income tax of about 3.8 percent, which is not included.",

      "deferred.basis" =>
        "%{rate} on the whole balance of %{amount}, taxed as income on withdrawal.",
      "deferred.whole_balance_caveat" =>
        "The whole balance is taxed here, not just the gain: the contributions went in pre-tax.",
      "deferred.lump_sum_caveat" =>
        "A single rate of %{rate} on %{amount} is exact within one tax band and understates a withdrawal large enough to climb into the next.",

      "gb_capital_gains.band_from_marginal" =>
        "The %{rate} CGT band was taken from your declared marginal income-tax rate.",
      "gb_capital_gains.allowance_ignored" =>
        "This ignores the £3,000 annual exempt amount, which applies once across all your disposals, not per account.",

      "gb_pension.basis" =>
        "The first quarter is tax-free; %{rate} on the remaining %{amount}.",
      "gb_pension.note" =>
        "A quarter of a UK pension can normally be taken tax-free; the rest is taxed as income on withdrawal.",

      "in_equity.long_term_assumed" =>
        "The %{rate} long-term rate is assumed. Equity held for 12 months or less is taxed at the higher short-term rate; Sure does not record holding periods.",
      "in_equity.exemption_ignored" =>
        "This ignores the ₹1.25 lakh annual long-term equity exemption, which applies once across all disposals, not per account."
    }.freeze

    # What a sentence asks of the reader. Three answers and no more, because a
    # reader can act on three: nothing, type a figure, or accept that this
    # account has no number.
    #
    #   :note    -- true, worth saying, asks nothing.
    #   :gap     -- something is missing or contradictory, and correcting it
    #               would change the figure. The figure still stands.
    #   :blocker -- nothing was computed, and nothing this page can say will
    #               change that.
    #
    # It is a property of the sentence rather than of the occasion, which is
    # why it is a table beside the English instead of an argument at the ~60
    # places a message is raised. A given key always means the same kind of
    # thing to a reader; if it did not, it would be two keys.
    #
    # Every key in TEXTS appears here, including the ones that are obviously
    # notes -- the basis lines, the rules-screen prose. `fetch` with a default
    # would have been shorter and would have meant "nobody has decided" and
    # "somebody decided :note" are written identically. The completeness test
    # in test/models/tax/messages_test.rb is what makes that worth the length:
    # a key added without a line here fails the build, at the moment its author
    # is still holding the reason.
    #
    # On contradictions -- a declared deducted portion larger than the total
    # paid in, payments above a PEA's legal ceiling. Nothing is *missing*
    # there, so by the letter of ":gap" they would be notes. They are gaps,
    # because severity sorts by what the reader does about it and the answer is
    # the same in both cases: open the form and put a figure right. A
    # demonstrably wrong figure has a better claim on the reader's attention
    # than an absent one, and burying it behind a disclosure would be the worse
    # error of the two.
    SEVERITY = {
      # Refusal scaffolding. `base.declare` only ever accompanies a reason that
      # is itself a blocker; `base.cannot_be_computed` is a basis line and
      # never a warning at all.
      "base.declare" => :blocker,
      "base.cannot_be_computed" => :note,
      "base.cost_basis_footnote" => :note,

      # The rules screen describes a rule, never an account, so none of it asks
      # the reader for anything.
      "formula.nothing_taxed" => :note,
      "formula.headline" => :note,
      "formula.needs" => :note,
      "formula.rate_with_percent" => :note,
      "formula.head_with_percent" => :note,
      "formula.head_named_rate" => :note,
      "formula.head_unresolved_rate" => :note,
      "formula.condition_mature" => :note,
      "formula.condition_immature" => :note,
      "formula.condition_immature_unknown_clock" => :note,
      "formula.clock_years" => :note,
      "formula.clock_unknown" => :note,
      "formula.window_between" => :note,
      "formula.window_from" => :note,
      "formula.window_until" => :note,
      "formula.window_unreadable" => :note,

      "fr_securities.no_cost_basis" => :blocker,
      "fr_securities.latent_loss" => :note,
      "fr_securities.declared_cost" => :note,
      "fr_securities.flat_tax_assumed" => :note,
      "fr_securities.basis" => :note,

      "fr_pea.no_paid_in" => :blocker,
      # The figure stands and would move if the versements were declared,
      # which is the definition of a gap. Both of these are the point of this
      # part: the row that used to be blank now carries a number and the
      # sentence that says what is wrong with it.
      "fr_pea.computed_from_cost_basis" => :gap,
      "fr_pea.loss" => :note,
      "fr_pea.no_opening_date" => :gap,
      "fr_pea.opening_date_floor_only" => :gap,
      # A lower bound that already clears the clock is not a gap: declaring the
      # exact date would move nothing. Worth saying once, quietly.
      "fr_pea.mature_by_lower_bound" => :note,
      "fr_pea.immature" => :note,
      "fr_pea.exceeds_ceiling" => :gap,
      "fr_pea.taux_historiques" => :note,
      "fr_pea.basis_mature" => :note,
      "fr_pea.basis_immature" => :note,

      "fr_deposit.taxable_savings" => :note,
      "fr_deposit.checking" => :note,
      "fr_deposit.unknown_product" => :gap,
      # "quite legally" -- the sentence normalises itself and there is nothing
      # to correct. Unlike the PEA ceiling, which is a legal maximum, and whose
      # breach means a declared figure is wrong.
      "fr_deposit.exceeds_ceiling" => :note,
      "fr_deposit.basis_cash" => :note,
      "fr_deposit.note_interest_taxed_as_it_arises" => :note,

      "fr_capital_and_gains.no_paid_in" => :blocker,
      "fr_capital_and_gains.computed_from_cost_basis" => :gap,
      "fr_capital_and_gains.no_deducted" => :gap,
      "fr_capital_and_gains.deducted_exceeds_total" => :gap,
      "fr_capital_and_gains.lump_sum_caveat" => :note,
      "fr_capital_and_gains.non_deducted_untaxed" => :note,
      "fr_capital_and_gains.whole_wrapper_lump_sum" => :note,
      "fr_capital_and_gains.mixed_election_not_modelled" => :note,
      "fr_capital_and_gains.basis" => :note,

      "composed.invalid_formula" => :blocker,
      "composed.missing_facts" => :blocker,
      "composed.no_deducted_portion" => :gap,
      "composed.deducted_exceeds_total" => :gap,
      "composed.no_opening_date" => :gap,
      "composed.opening_date_floor_only" => :gap,
      "composed.known_since" => :note,
      "composed.immature" => :note,
      "composed.not_taxed_on_liquidation" => :note,
      "composed.term" => :note,
      "composed.term_household_rate" => :note,
      "composed.basis" => :note,

      # The sentences an unmodelled account gets are one explanation in three
      # parts, and they are all blockers so that they stay together. A note
      # among them would sit behind a disclosure while its own first clause sat
      # above it.
      "unknown.no_rule" => :blocker,
      "unknown.treatment_is_classification" => :blocker,
      # Never emitted on its own -- it is interpolated into the sentence above,
      # so this severity is never consulted. Listed because the test demands
      # every key be listed, and because the day it is raised directly the
      # answer should already be here.
      "unknown.suggestion" => :note,
      "unknown.needs_custom_rule" => :blocker,

      "exempt.basis" => :note,
      "exempt.exceeds_ceiling" => :note,

      # Sure's classification and the rule that ran disagree. No per-account
      # form settles that -- see ASKS_FOR -- so these keep saying so, which is
      # the point: an unresolved disagreement about whether an account is taxed
      # at all should not go quiet because somebody opened a form once.
      "treatment.tax_exempt_but_taxed" => :gap,
      "treatment.deferred_or_advantaged_but_cto" => :gap,

      "registry.no_value" => :blocker,

      "not_modelled.excluded_from_total" => :blocker,
      "not_modelled.assurance_vie" => :blocker,
      "not_modelled.crypto" => :blocker,
      "not_modelled.property" => :blocker,

      "assumptions.marginal_rate_caveat" => :gap,

      "securities_gain.no_cost_basis" => :blocker,
      "us_long_term.rate_assumed" => :gap,
      "us_long_term.bracket" => :gap,
      "deferred.lump_sum_caveat" => :gap,
      "gb_capital_gains.allowance_ignored" => :gap,
      "in_equity.long_term_assumed" => :gap,
      "in_equity.exemption_ignored" => :gap
    }.freeze

    # Which fact a gap is about, where a form on the account itself can take
    # it.
    #
    # This exists for one purpose. A household that has opened the form and
    # chosen not to fill a field in has answered the question, and the report
    # should say so once and then be quiet -- see TaxReportsHelper, where the
    # demotion happens. It happens at the view edge rather than here because
    # the engine's job is to keep saying the true thing and the page's job is
    # to decide how loudly.
    #
    # A gap with no entry is one no account form can close: a marginal rate
    # belongs to the household rather than to an account, and a disagreement
    # with Sure's own classification is settled on the Taxes screen or not at
    # all. Those never quieten, which is why absence is the default rather than
    # something a key has to declare.
    ASKS_FOR = {
      "fr_pea.computed_from_cost_basis" => :paid_in,
      "fr_capital_and_gains.computed_from_cost_basis" => :paid_in,
      "fr_pea.no_opening_date" => :opened_on,
      "fr_pea.opening_date_floor_only" => :opened_on,
      "fr_pea.exceeds_ceiling" => :paid_in,
      "fr_deposit.unknown_product" => :product,
      "fr_capital_and_gains.no_deducted" => :paid_in_deducted,
      "fr_capital_and_gains.deducted_exceeds_total" => :paid_in_deducted,
      "composed.no_deducted_portion" => :paid_in_deducted,
      "composed.deducted_exceeds_total" => :paid_in_deducted,
      "composed.no_opening_date" => :opened_on,
      "composed.opening_date_floor_only" => :opened_on
    }.freeze

    def self.severity(key)
      SEVERITY.fetch(key.to_s, :note)
    end

    def self.asks_for(key)
      ASKS_FOR[key.to_s]
    end

    class UnknownMessage < ::StandardError; end

    # Every key the engine can emit, sentences and vocabulary together. This is
    # what the parity test walks, so a base added to Vocabulary without a
    # French name fails the build exactly like a warning would.
    def self.keys
      TEXTS.keys +
        Vocabulary::BASES.keys.map { |name| "bases.#{name}" } +
        Vocabulary::RATES.keys.map { |name| "rates.#{name}" } +
        Vocabulary::FACTS.keys.map { |name| "facts.#{name}" } +
        Vocabulary::CONNECTORS.keys.map { |name| "connectors.#{name}" } +
        Vocabulary::TREATMENTS.keys.map { |name| "treatments.#{name}" }
    end

    def self.template(key)
      TEXTS.fetch(key.to_s) do
        raise UnknownMessage, "no English text for tax message #{key.inspect}"
      end
    end

    # The English rendering, used by Message#to_s.
    #
    # Raises rather than returning the key when the key is unknown, and lets
    # KeyError through when a placeholder has no value. Both are bugs in this
    # module and both are silent in production if swallowed here: the first
    # prints an identifier at a reader, the second prints a sentence with a
    # hole in it. Neither is a thing a tax report should do.
    def self.render(key, args = {})
      vocabulary(key) || (template(key) % prepare(args))
    end

    # The vocabulary is not repeated here. Tax::Vocabulary already holds the
    # name of every base, rate and fact, the rules screen already renders those
    # names into its select menus, and a second copy in this hash would be a
    # second copy that drifts -- the dropdown offering "the gain over what was
    # paid in" while the warning beside it refuses "the gain over payments".
    # A message keyed `bases.x` therefore resolves through Vocabulary and takes
    # no arguments; everything else is a sentence and lives in TEXTS.
    def self.vocabulary(key)
      namespace, name = key.split(".", 2)
      return nil if name.nil?

      case namespace
      when "bases" then Vocabulary.base(name)
      when "rates" then Vocabulary.rate(name)
      when "facts" then Vocabulary.fact(name)
      when "connectors" then Vocabulary.connector(name)
      when "treatments" then Vocabulary.treatment(name)
      end
    end

    # The English rendering of a Message::List, used by List#to_s and by the
    # flattening below. A bare Array is a list joined with "and", which is what
    # every list in the module was before Rules::Composed needed "plus".
    def self.render_list(list)
      Vocabulary.to_sentence(
        list.items.map { |item| flatten(item) },
        word: list.connector && Vocabulary.connector(list.connector)
      )
    end

    # Arrays become sentences before interpolation, and a Message used as an
    # argument is rendered before the message that contains it.
    #
    # Nesting is what keeps "Declare the total paid in for this account to
    # compute it." translatable as two pieces rather than as one sentence per
    # missing fact. The scaffolding is one key, the fact is another, and a
    # language that orders them differently rewrites only the scaffolding.
    # Anything else passes through untouched, so a BigDecimal the caller
    # formatted stays formatted the way the caller meant.
    def self.prepare(args)
      args.to_h { |name, value| [ name.to_sym, flatten(value) ] }
    end
    private_class_method :prepare

    def self.flatten(value)
      case value
      when Message::List then render_list(value)
      when ::Array       then render_list(Message::List.new(value))
      when Message       then value.to_s
      # A Date arrives raw and is written out here rather than by the caller.
      # "2013-01-01" mid-sentence reads as a serial number, and "1 January
      # 2013" is a choice about language: the view edge hands the same Date to
      # I18n.l instead and gets "1 janvier 2013". A caller that formatted it
      # would have decided for both of them.
      when ::Date        then Vocabulary.date(value)
      else value
      end
    end
    private_class_method :flatten
  end
end
