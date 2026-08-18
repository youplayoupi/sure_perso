# frozen_string_literal: true

require "test_helper"

# The Rails half of the module: the three tables, and the one class that turns
# Sure's records into the value objects the engine consumes.
#
# The arithmetic is not retested here -- engine_test.rb already covers it
# without a database, and repeating it through fixtures would only make it
# slower to find out which layer broke. What is tested here is the boundary:
# that the right facts reach the engine, and that nothing this module adds can
# damage anything Sure already does.
module Tax
  class ProfileTest < ActiveSupport::TestCase
    setup do
      @account = accounts(:investment)
      # The fixtures are a US family. `product` only means anything for a
      # country this module has rules for, so the country is set explicitly
      # rather than left to chance -- an earlier version of this test passed
      # for the wrong reason because the validation was skipping on US.
      @account.family.update!(country: "FR")
    end

    test "a product cannot be set for a country this module has no rules for" do
      @account.family.update!(country: "US")
      profile = Profile.new(account: @account, product: "pea")

      assert_not profile.valid?
      assert_match(/no tax rules for US/, profile.errors[:product].first)
    end

    test "an account has at most one profile" do
      Profile.create!(account: @account, paid_in: 1000)

      duplicate = Profile.new(account: @account, paid_in: 2000)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:account_id], "has already been taken"
    end

    test "a blank declaration is valid because a half-filled form must be savable" do
      assert Profile.new(account: @account).valid?
    end

    test "an unknown product is rejected before it can silently fall through" do
      profile = Profile.new(account: @account, product: "livretA")

      assert_not profile.valid?
      assert_match(/not a product this module knows about/, profile.errors[:product].first)
    end

    test "a known product is accepted" do
      assert Profile.new(account: @account, product: "livret_a").valid?
    end

    test "a future opening date is rejected" do
      profile = Profile.new(account: @account, opened_on: Date.current + 1)

      assert_not profile.valid?
    end

    test "a deduction larger than the payments is saved, and flagged rather than blocked" do
      profile = Profile.new(account: @account, paid_in: 100, paid_in_deducted: 200)

      assert profile.valid?, "the user may still be typing"
      assert profile.deduction_exceeds_payments?
    end

    test "deleting the account takes the profile with it and does not raise" do
      Profile.create!(account: @account, paid_in: 1000)

      assert_difference -> { Profile.count }, -1 do
        @account.destroy
      end
    end
  end

  # -------------------------------------------------------------------------

  class CustomRuleTest < ActiveSupport::TestCase
    setup do
      @family = families(:dylan_family)
      @account = accounts(:investment)
    end

    test "kind must name a rule from the catalogue" do
      rule = CustomRule.new(family: @family, accountable_type: "Investment", kind: "Kernel")

      assert_not rule.valid?
      assert_includes rule.errors[:kind], "is not a rule this module offers"
    end

    test "a catalogue kind builds a real rule object" do
      rule = CustomRule.new(
        family: @family, accountable_type: "Investment",
        subtype: "per", kind: "fr_capital_and_gains"
      )

      assert rule.valid?
      assert_instance_of Rules::Fr::CapitalAndGains, rule.to_rule
    end

    test "a rule targets either an account or a type, never both" do
      both = CustomRule.new(
        family: @family, account: @account,
        accountable_type: "Investment", kind: "fr_pea"
      )
      neither = CustomRule.new(family: @family, kind: "fr_pea")

      assert_not both.valid?
      assert_not neither.valid?
    end

    test "a rule cannot be pinned to another family's account" do
      rule = CustomRule.new(family: families(:empty), account: @account, kind: "fr_pea")

      assert_not rule.valid?
      assert_includes rule.errors[:account], "does not belong to this family"
    end

    test "a kind no longer offered degrades to no rule instead of raising" do
      # Simulates a row written by a future version of the module and read back
      # by an older one. The engine already handles a missing rule by refusing
      # to compute; blowing up the whole report would be worse.
      assert_nil Catalogue.build("fr_something_removed")
    end

    test "a composed rule carries its formula in params and builds from it" do
      rule = CustomRule.new(
        family: @family, accountable_type: "Investment", subtype: "per",
        kind: "composed",
        params: {
          "name" => "My PER",
          "terms" => [
            { "base" => "paid_in_deducted", "rate" => "household_rate" },
            { "base" => "gain_over_paid_in", "rate" => "flat_tax" }
          ]
        }
      )

      assert rule.valid?, rule.errors.full_messages.inspect
      assert rule.composed?
      assert_instance_of Rules::Composed, rule.to_rule
      assert_equal 2, rule.formula.terms.length
    end

    # A rule saved before the income-tax scale was replaced by a declared
    # marginal rate. Refusing it on upgrade to make a point about vocabulary
    # would be the module failing at its actual job: the arithmetic the
    # household asked for is the arithmetic they now get, under the new name.
    test "a rule stored under the old rate name still validates and reads as the new one" do
      rule = CustomRule.new(
        family: @family, accountable_type: "Investment", subtype: "per",
        kind: "composed",
        params: {
          "name" => "My PER",
          "terms" => [ { "base" => "paid_in_deducted", "rate" => "progressive" } ]
        }
      )

      assert rule.valid?, rule.errors.full_messages.inspect
      assert_equal "household_rate", rule.formula.terms.first.rate
    end

    test "a composed rule with arithmetic that does not add up is rejected at save time" do
      # The engine refuses at run time on the same conditions, so nothing wrong
      # can be computed either way. This is so the author finds out while the
      # form is still on screen rather than months later in a report footnote.
      rule = CustomRule.new(
        family: @family, accountable_type: "Investment",
        kind: "composed",
        params: { "terms" => [ { "base" => "full_value", "rate" => "literal", "literal_rate" => "30" } ] }
      )

      assert_not rule.valid?
      assert_match(/not between 0 and 1/, rule.errors[:params].join)
    end

    test "a built-in rule reports the formula declared in its class" do
      rule = CustomRule.new(family: @family, accountable_type: "Investment", kind: "fr_pea")

      assert_not rule.composed?
      assert_equal 5, rule.formula.maturity_years
    end

    test "params a rule does not understand are dropped rather than crashing the report" do
      # A row written by a newer version of the module, read by this one. It
      # should cost the reader nothing: the rule still builds from the keys it
      # recognises. `new(**unexpected)` would be an ArgumentError raised once
      # per account, which is a blank page instead of a report.
      built = Catalogue.build("composed", { "terms" => [], "invented_later" => true })

      assert_instance_of Rules::Composed, built
    end
  end

  # -------------------------------------------------------------------------

  class RateCorrectionTest < ActiveSupport::TestCase
    setup do
      @family = families(:dylan_family)
      Tax.reset_rate_tables!
    end

    teardown { Tax.reset_rate_tables! }

    test "a family with no corrections gets the shipped table, not a rebuilt one" do
      # Identity, not equality. Rebuilding the table per request for the
      # overwhelming majority of families who have corrected nothing would be
      # a parse of the YAML on every page load.
      assert_same Tax.rate_table("FR"), Tax.rate_table_for(@family, "FR")
    end

    test "a correction changes what the family's report uses and nobody else's" do
      RateCorrection.create!(
        family: @family, country: "FR",
        overrides: { "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.20 } ] }
      )

      on = Date.new(2026, 6, 1)

      assert_equal BigDecimal("0.20"), Tax.rate_table_for(@family, "FR").social_charges(on)
      assert_equal BigDecimal("0.186"), Tax.rate_table_for(families(:empty), "FR").social_charges(on)
      assert_equal BigDecimal("0.186"), Tax.rate_table("FR").social_charges(on),
                   "the shipped table has been mutated -- this leaks one family's rates to everyone"
    end

    test "a correction that is not a rate the module reads is refused" do
      row = RateCorrection.new(
        family: @family, country: "FR",
        overrides: { "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 20 } ] }
      )

      assert_not row.valid?
      assert_match(/not between 0 and 1/, row.errors[:overrides].join)
    end

    test "a country with no rate file cannot be corrected" do
      row = RateCorrection.new(family: @family, country: "ZZ", overrides: {})

      assert_not row.valid?
      assert_includes row.errors[:country], "has no rate file in this module yet"
    end

    test "one document per family per country" do
      RateCorrection.create!(family: @family, country: "FR")
      duplicate = RateCorrection.new(family: @family, country: "fr")

      assert_not duplicate.valid?, "country should be normalised before the uniqueness check"
    end

    test "corrections survive a round trip through jsonb" do
      RateCorrection.create!(
        family: @family, country: "FR",
        overrides: { "products" => { "pea" => { "maturity_years" => 8 } } }
      )

      assert_equal 8, Tax.rate_table_for(@family, "FR").maturity_years("pea")
      assert_equal [ "products" ], RateCorrection.for(@family, "FR").edited_sections
    end
  end

  # -------------------------------------------------------------------------

  # The fourth table, and the only one that stores something about the people
  # rather than about their accounts.
  #
  # The controller test covers the form; what is here is the contract the rest
  # of the module reads it through, which is two class methods and a predicate.
  # `marginal_rate_for` is the one that matters: it is called on every report,
  # for families that have never opened the tax settings at all, and its nil is
  # load-bearing -- it is what makes the report label its own total provisional
  # instead of quietly computing against a placeholder.
  class HouseholdTest < ActiveSupport::TestCase
    setup { @family = families(:dylan_family) }

    test "a household that has said nothing has no rate, and saying so is not an error" do
      assert_nil Household.marginal_rate_for(@family)
      assert_not Household.for(@family).declared?
      assert_not Household.for(@family).persisted?
    end

    test "a declared rate is what the engine is handed" do
      Household.create!(family: @family, marginal_rate: BigDecimal("0.41"))

      assert_equal BigDecimal("0.41"), Household.marginal_rate_for(@family)
    end

    # Reports are rendered for whoever is signed in, and `Current.family` is
    # nil in more places than one would like -- a background job, a session
    # that expired mid-request. Raising here would turn a missing session into
    # a 500 on a page whose whole job is to degrade gracefully.
    test "no family at all is undeclared rather than an exception" do
      assert_nil Household.marginal_rate_for(nil)
    end

    test "one row per family" do
      Household.create!(family: @family, marginal_rate: BigDecimal("0.30"))
      duplicate = Household.new(family: @family, marginal_rate: BigDecimal("0.41"))

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:family_id], "has already been taken"
    end

    test "for returns the existing row rather than a second one" do
      row = Household.create!(family: @family, marginal_rate: BigDecimal("0.30"))

      assert_equal row, Household.for(@family)
    end

    # The column holds a fraction, so the range is the range. This is the last
    # guard before a rate multiplies a whole PER withdrawal, and it is worth
    # having at the model rather than only at the form because the form is not
    # the only thing that writes here -- a console, a future import, an upgrade
    # script.
    test "a rate outside nought to one is refused" do
      assert_not Household.new(family: @family, marginal_rate: BigDecimal("1.3")).valid?
      assert_not Household.new(family: @family, marginal_rate: BigDecimal("-0.05")).valid?
    end

    test "the boundaries are inside the range" do
      assert Household.new(family: @family, marginal_rate: BigDecimal("0")).valid?
      assert Household.new(family: @family, marginal_rate: BigDecimal("1")).valid?
    end

    # Nil is a legitimate stored state as far as the column is concerned, and
    # it has to be, because `for` builds an unsaved row with no rate on it
    # every time the settings page renders for a household that has not
    # declared one.
    test "no rate is a valid row, and it is not a declaration" do
      row = Household.new(family: @family)

      assert row.valid?
      assert_not row.declared?
    end

    # Zero is a rate someone can genuinely be on, and it is not the same
    # statement as saying nothing. The report treats the two differently -- one
    # is an answer, the other is a caveat -- so the predicate must too.
    test "a zero rate is a declaration" do
      assert Household.new(family: @family, marginal_rate: BigDecimal("0")).declared?
    end

    test "a household goes when its family does" do
      family = families(:empty)
      Household.create!(family: family, marginal_rate: BigDecimal("0.30"))

      family.destroy

      assert_nil Household.find_by(family_id: family.id),
                 "the row outlived the family it describes"
    end
  end

  # -------------------------------------------------------------------------

  class CatalogueTest < ActiveSupport::TestCase
    test "every advertised kind builds and is a rule" do
      Catalogue.kinds.each do |kind|
        rule = Catalogue.build(kind)

        assert_kind_of Rules::Base, rule, "#{kind} did not build a rule"
        assert_equal kind, rule.rule_id, "#{kind} builds a rule with a different id"
      end
    end

    test "every kind has a description, because a menu of bare identifiers is not a choice" do
      Catalogue.kinds.each do |kind|
        assert Catalogue.description(kind).present?, "#{kind} has no description"
      end
    end
  end

  # -------------------------------------------------------------------------

  class SubjectBuilderTest < ActiveSupport::TestCase
    setup do
      @family = families(:dylan_family)
      @family.update!(country: "FR")

      # A French family holding euros: the base case, and the one where no
      # conversion happens at all. The currency tests further down override
      # this explicitly, so that a test about payments in is not quietly also a
      # test about exchange rates.
      @family.accounts.update_all(currency: "EUR")
      @builder = SubjectBuilder.new(@family)
    end

    test "the country comes from the family, falling back to the default" do
      assert_equal "FR", SubjectBuilder.new(@family).country

      @family.update_column(:country, nil)
      assert_equal Tax::DEFAULT_COUNTRY, SubjectBuilder.new(@family).country
    end

    test "liabilities are out of scope" do
      types = @builder.subjects.map(&:accountable_type)

      assert_not_includes types, "CreditCard"
      assert_not_includes types, "Loan"
      assert_not_includes types, "OtherLiability"
    end

    test "it carries Sure's own subtype rather than inventing one" do
      account = accounts(:investment)
      account.update!(subtype: "brokerage")

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_equal "Investment", subject.accountable_type
      assert_equal "brokerage", subject.subtype
    end

    test "a nil subtype stays nil rather than being guessed at" do
      account = accounts(:investment)
      account.update!(subtype: nil)

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_nil subject.subtype
    end

    test "declared facts reach the engine" do
      account = accounts(:investment)
      Profile.create!(
        account: account, product: "pea",
        opened_on: Date.new(2015, 1, 1), paid_in: 1234.56
      )

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_equal "pea", subject.product
      assert_equal Date.new(2015, 1, 1), subject.opened_on
      assert_equal BigDecimal("1234.56"), subject.paid_in
      assert_includes subject.declared, :paid_in
    end

    test "an account with no profile is unchanged from before this module existed" do
      subject = @builder.subjects.find { |s| s.id == accounts(:investment).id }

      assert_nil subject.product
      assert_nil subject.paid_in
      assert_nil subject.opened_on
      assert_empty subject.declared
    end

    # Sure's opening date, and the three ways it can be wrong to use.
    #
    # `Account#opening_anchor_date` always returns something, and only one of
    # the things it can return is a statement about when the account began.
    # These three tests pin which one this module is willing to believe,
    # because the failure mode is silent: a PEA that looks younger than it is
    # goes from exempt to taxed at the full flat rate, confidently.

    # Set an opening anchor without going through Account#set_opening_anchor_balance,
    # which would also enqueue a sync.
    def anchor(account, on:, balance: 1_000)
      Account::OpeningBalanceManager.new(account)
                                    .set_opening_balance(balance: balance, date: on)
    end

    def subject_for(account)
      SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }
    end

    # Put the securities in the same currency as the account holding them.
    #
    # `Account#current_holdings` scopes to the account's own currency, and this
    # class moves every account to euros in `setup`, so the dollar-denominated
    # holdings in the fixtures fall out of the query and every account looks
    # like it holds nothing. That is a fixture artefact rather than a real
    # shape -- Sure keeps one currency per account -- but it silently turns a
    # cost basis assertion into a test of the empty case, which is exactly the
    # test that already passes for the wrong reason.
    #
    # The trades move too. `Holding#avg_cost` falls back to totalling them, and
    # that query converts through `COALESCE(exchange_rates.rate, 1)`, so a
    # dollar trade under a euro account would be counted at par. Leaning on
    # that would make these tests pass on a fabricated rate, which is the one
    # thing this module refuses to do anywhere else.
    def in_euros(account)
      account.holdings.update_all(currency: "EUR")
      Trade.where(id: account.entries.where(entryable_type: "Trade").select(:entryable_id))
           .update_all(currency: "EUR")
      account
    end

    # An anchor at zero is the account beginning. Nothing was in it, so there
    # is nothing the date could be later than.
    test "an anchor with no money behind it is Sure saying when the account began" do
      account = accounts(:investment)
      anchor(account, on: Date.new(2010, 1, 1), balance: 0)

      subject = subject_for(account)

      assert_equal Date.new(2010, 1, 1), subject.opened_on
      assert_nil subject.known_since, "an opening date makes a lower bound redundant"
      # And not `declared`: this is Sure answering, not the household. The
      # distinction matters to rules that say where a figure came from.
      assert_not_includes subject.declared, :opened_on
    end

    # An anchor carrying a balance is the opposite statement. Money was already
    # in the account on that date, so the account existed before it -- which
    # makes the date a floor on how long it has been held rather than the date
    # it was opened.
    #
    # This is the case that mattered in practice. Sure writes an anchor for
    # every manually created account, dated when the balance was entered, and
    # the earlier version of this guard asked only whether an anchor existed.
    # Every wrapper in a hand-entered portfolio therefore came back zero years
    # old, which turns a mature PEA into one taxed at the full flat rate.
    test "an anchor with money behind it is a lower bound, not an opening date" do
      account = accounts(:investment)
      anchor(account, on: Date.new(2010, 1, 1), balance: 1_000)

      subject = subject_for(account)

      assert_nil subject.opened_on
      assert_equal Date.new(2010, 1, 1), subject.known_since
    end

    test "the earliest-entry fallback is refused rather than mistaken for either" do
      account = accounts(:investment)

      # No anchor, so Sure falls back to the oldest entry on file -- fine for
      # drawing a balance chart from the left edge, and not an answer to "when
      # was this opened". The account is older than its Sure history whenever
      # the history was imported, which is most of the time.
      assert_not account.has_opening_anchor?
      assert_not_nil account.opening_anchor_date

      subject = subject_for(account)

      assert_nil subject.opened_on
      assert_nil subject.known_since
    end

    test "a declared opening date overrides Sure's anchor" do
      account = accounts(:investment)
      anchor(account, on: Date.new(2010, 1, 1))
      Profile.create!(account: account, opened_on: Date.new(2005, 6, 30))

      subject = subject_for(account)

      # An anchor is a balance's starting point and can legitimately sit later
      # than the first payment in, which is the date the five-year clocks run
      # from. So the household's own date wins where there is one.
      assert_equal Date.new(2005, 6, 30), subject.opened_on
      assert_includes subject.declared, :opened_on
      # And the bound goes with it. Two facts about one clock, one of them
      # strictly weaker, is an invitation for a rule to quote the weaker one
      # beside an answer it did not need it for.
      assert_nil subject.known_since
    end

    # -- cost basis --------------------------------------------------------

    # The column Sure stores is an average cost *per share*, written by
    # Holding::ForwardCalculator as total cost over total quantity. Summing it
    # across a portfolio adds prices together, which is not the cost of
    # anything: one share of an expensive security would weigh as much as a
    # thousand of a cheap one. This is the test that would have caught it.
    test "cost basis multiplies the per-share figure by the quantity held" do
      account = in_euros(accounts(:investment))
      account.holdings.update_all(cost_basis: 100)

      holding = account.current_holdings.first
      subject = subject_for(account)

      assert_equal 10, holding.qty
      assert_equal BigDecimal(1_000), subject.cost_basis
    end

    # A null column is not the same as an unknowable cost. Sure holds the
    # trades and totals them on demand through Holding#avg_cost; refusing on a
    # null column meant refusing accounts whose entire purchase history is on
    # file, which is most imported ones.
    test "a null cost basis column still has a cost where the trades are on file" do
      account = in_euros(accounts(:investment))
      account.holdings.update_all(cost_basis: nil)

      subject = subject_for(account)

      # The fixture holds ten shares bought at 214.
      assert_equal BigDecimal(2_140), subject.cost_basis
    end

    test "cost basis is nil rather than a partial sum when one holding has neither" do
      account = in_euros(accounts(:investment))
      account.holdings.update_all(cost_basis: nil)
      account.entries.where(entryable_type: "Trade").destroy_all

      subject = subject_for(account)

      # A partial sum understates cost basis, which overstates the gain, which
      # overstates the tax while looking authoritative. Nil makes the rule say
      # so out loud instead.
      assert_nil subject.cost_basis
    end

    test "it reads Sure's tax_treatment without acting on it" do
      subject = @builder.subjects.find { |s| s.id == accounts(:investment).id }

      assert_includes [ nil, :taxable, :tax_deferred, :tax_exempt, :tax_advantaged ],
                      subject.tax_treatment
    end

    test "a custom rule for the family reaches the registry" do
      CustomRule.create!(
        family: @family, accountable_type: "Investment",
        subtype: accounts(:investment).subtype, kind: "fr_capital_and_gains"
      )

      registry = SubjectBuilder.new(@family).registry

      assert registry.custom?("Investment", accounts(:investment).subtype)
    end

    # -- currency ----------------------------------------------------------
    #
    # The thresholds this module applies are euro amounts, not ratios, so the
    # arithmetic has to reach the rules already denominated in euros. These
    # tests exist because the first version of the report summed dollars and
    # printed the total with a euro sign.

    test "the report is denominated in the rate table's currency, not the family's" do
      @family.update!(currency: "USD")

      assert_equal "EUR", SubjectBuilder.new(@family).report_currency
    end

    test "every subject carries the report currency, so the total can be summed at all" do
      currencies = SubjectBuilder.new(@family).subjects.map(&:currency).uniq

      assert_equal [ "EUR" ], currencies
    end

    test "a foreign balance is converted rather than added as if it were euros" do
      account = accounts(:investment)
      account.update!(currency: "USD")
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                           rate: 0.5, date: Date.current)

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_equal BigDecimal(account.balance.to_s) * BigDecimal("0.5"), subject.value
    end

    test "declared payments are converted too, or the gain would be computed off two scales" do
      account = accounts(:investment)
      account.update!(currency: "USD")
      Profile.create!(account: account, paid_in: 1000)
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                           rate: 0.5, date: Date.current)

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_equal BigDecimal("500"), subject.paid_in
    end

    test "no rate on file means no value, not a rate of one" do
      # Sure's own rates_for falls back to 1 and logs. For a net worth widget
      # that is a reasonable trade; here it would state that a dollar is a euro.
      account = accounts(:investment)
      account.update!(currency: "USD")
      ExchangeRate.where(from_currency: "USD", to_currency: "EUR").delete_all

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_nil subject.value
    end

    test "a rate older than the lookback window is not used" do
      account = accounts(:investment)
      account.update!(currency: "USD")
      ExchangeRate.where(from_currency: "USD", to_currency: "EUR").delete_all
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.5,
                           date: Date.current - (SubjectBuilder::RATE_LOOKBACK_DAYS + 1))

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_nil subject.value
    end

    test "the most recent rate in the window wins" do
      account = accounts(:investment)
      account.update!(currency: "USD")
      ExchangeRate.where(from_currency: "USD", to_currency: "EUR").delete_all
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.4,
                           date: Date.current - 10)
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: 0.9,
                           date: Date.current - 1)

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

      assert_equal BigDecimal(account.balance.to_s) * BigDecimal("0.9"), subject.value
    end

    test "an unvalued account is refused rather than taxed as zero" do
      subject = Subject.new(name: "Unconvertible", value: nil,
                            accountable_type: "Depository", subtype: "checking",
                            currency: "EUR")

      result = Registry.new(country: "FR").apply(
        subject, on: Date.current,
        rates: Tax.rate_table("FR"), assumptions: Assumptions.new
      )

      assert_not result.modelled?
      assert_nil result.tax
      assert_nil result.gross
      assert_match(/excluded from the totals/, result.warnings.join(" "))
    end

    test "it issues no writes" do
      # The strongest claim this module makes is that it cannot change any of
      # Sure's numbers. Asserting it is cheap; trusting it is not.
      assert_no_changes -> { [ Account.count, Holding.count, Entry.count, Balance.count ] } do
        SubjectBuilder.new(@family).subjects
      end
    end
  end

  # -------------------------------------------------------------------------

  class CoverageTest < ActiveSupport::TestCase
    setup do
      @coverage = Coverage.new(Registry.new(country: "FR"))
    end

    test "it enumerates every type Sure knows about that the report can tax" do
      assert_equal (Accountable::TYPES - SubjectBuilder::EXCLUDED_TYPES).sort,
                   @coverage.by_type.keys.sort
    end

    # The two lists are derived from one another, so this is really asserting
    # that nobody has restated the exclusions somewhere. Offering a tax rule
    # for a credit card would be offering a rule that can never fire, and
    # counting it as an uncovered product would understate coverage for a
    # reason that has nothing to do with tax.
    test "liabilities are out of scope rather than uncovered" do
      assert SubjectBuilder::EXCLUDED_TYPES.any?
      assert_empty @coverage.entries.map(&:accountable_type) & SubjectBuilder::EXCLUDED_TYPES
    end

    test "an explicit type list still overrides the default" do
      only_crypto = Coverage.new(Registry.new(country: "FR"), types: %w[Crypto])

      assert_equal %w[Crypto], only_crypto.by_type.keys
    end

    test "partitioning splits held products from the rest of Sure's catalogue" do
      held, rest = @coverage.partition_by(Set[[ "Investment", "pea" ]])

      assert_equal [ [ "Investment", "pea" ] ], held.map { |e| [ e.accountable_type, e.subtype ] }
      assert_operator rest.size, :>, 50, "Sure's subtype catalogue got smaller than expected"
    end

    test "partitioning loses nothing" do
      # The disclosure on the settings page is the module's promise that a
      # subtype added by a future Sure release still appears. That only holds
      # if the two halves add back up to the whole.
      held, rest = @coverage.partition_by(Set[[ "Investment", "pea" ], [ "Crypto", "crypto_wallet" ]])

      assert_equal @coverage.entries.size, held.size + rest.size
      assert_equal @coverage.entries.map(&:label).sort, (held + rest).map(&:label).sort
    end

    test "an empty key set puts everything on the far side" do
      held, rest = @coverage.partition_by(Set.new)

      assert_empty held
      assert_equal @coverage.entries.size, rest.size
    end

    test "a subtype with no rule is reported as uncovered rather than omitted" do
      # This is the whole point: a future Sure release adding a subtype must
      # show up here on upgrade day, not be quietly swept into another rule.
      assert_operator @coverage.uncovered_count, :>, 0
      assert @coverage.uncovered.all? { |e| e.rule_id.nil? }
    end

    test "covered entries name the rule that will actually run" do
      pea = @coverage.entries.find { |e| e.accountable_type == "Investment" && e.subtype == "pea" }

      assert pea.covered?
      assert_equal "fr_pea", pea.rule_id
    end

    test "an uncovered entry suggests a rule from Sure's own classification" do
      suggested = @coverage.uncovered.select(&:suggested_rule_id)

      suggested.each do |entry|
        assert Catalogue.include?(entry.suggested_rule_id),
               "#{entry.label} suggests #{entry.suggested_rule_id}, which is not in the catalogue"
      end
    end
  end

  # -------------------------------------------------------------------------

  class ProductsHeldTest < ActionView::TestCase
    tests TaxReportsHelper

    setup do
      @family = families(:dylan_family)
    end

    test "it reports the type and subtype pairs the family actually holds" do
      held = tax_products_held(@family)

      assert held.any?
      @family.accounts.visible.each do |account|
        next if SubjectBuilder::EXCLUDED_TYPES.include?(account.accountable_type)

        assert_includes held, [ account.accountable_type, account.subtype ]
      end
    end

    test "the subtype reported is the one Sure would act on" do
      # `accounts.subtype` is a stale column; the value Sure reads is on the
      # delegated accountable. Plucking the column returns nil for every
      # account, and nil is itself a legitimate key here -- it is what a type
      # with no subtypes looks like -- so the mistake does not raise. It just
      # files every product the family holds under the wrong key, which on the
      # settings page means burying all of them behind the disclosure.
      account = @family.accounts.create!(
        name: "PEA", balance: 1000, currency: "EUR",
        accountable: Investment.new, subtype: "pea"
      )

      assert_equal "pea", account.reload.subtype
      assert_includes tax_products_held(@family), [ "Investment", "pea" ]
    end

    test "liabilities are not products, so they are not held" do
      # Same scoping as the report, asserted rather than assumed: if these two
      # ever disagree, the settings page would offer a rule for an account the
      # report never looks at.
      held = tax_products_held(@family)

      assert_empty held.map(&:first).to_set & SubjectBuilder::EXCLUDED_TYPES.to_set
    end

    test "no family means nothing held, rather than an exception" do
      assert_empty tax_products_held(nil)
    end
  end

  # -------------------------------------------------------------------------

  # The hint a form shows beside a field, resolved for the rule that will read
  # it.
  #
  # This is a test about a fallback chain, which is why the chain lives in a
  # helper rather than inline in ERB. The failure it guards against is silent:
  # one hint per fact for the whole module meant the opening-date hint
  # explained the PEA's five-year clock on every account that asked for a date,
  # including the ones where the date starts no clock at all. Nothing renders
  # wrong, nothing raises -- the reader is simply told something untrue about
  # their own account and has no way to know it was written for another one.
  class FactHintTest < ActionView::TestCase
    tests TaxReportsHelper

    test "a rule with something of its own to say about a fact says it" do
      generic = I18n.t("tax.profiles.fields.opened_on.hint")
      specific = tax_fact_hint(:opened_on, "fr_pea")

      assert_not_equal generic, specific
      assert_equal I18n.t("tax.rules.fr_pea.facts.opened_on.hint"), specific
    end

    test "a rule with nothing of its own to say falls back to the generic hint" do
      # The point of the fallback, and the reason this list is the exceptions
      # rather than the cross product of every rule and every fact: a rule
      # added tomorrow inherits sentences that are already true instead of
      # rendering a missing key until somebody writes four more.
      assert_equal I18n.t("tax.profiles.fields.product.hint"),
                   tax_fact_hint(:product, "fr_pea")
    end

    test "no rule at all still produces a sentence" do
      # Rules::Unknown and Rules::NotModelled resolve to no formula, and the
      # controller then asks for no facts -- but a blank rule_id must not turn
      # into a lookup for `tax.rules..facts.x.hint`.
      assert_equal I18n.t("tax.profiles.fields.paid_in.hint", currency: "EUR"),
                   tax_fact_hint(:paid_in, nil, currency: "EUR")
    end

    test "the currency reaches the strings that ask for one" do
      assert_includes tax_fact_label(:paid_in, nil, currency: "EUR"), "EUR"
    end

    test "an override is available for labels as well as hints" do
      # Nothing overrides a label today; the cascade exists for the case where
      # a rule means something different by the same field, and asserting the
      # fallback here is what stops the label path from rotting unnoticed
      # before the first override lands.
      assert_equal I18n.t("tax.profiles.fields.opened_on.label"),
                   tax_fact_label(:opened_on, "fr_pea")
    end
  end

  # What colour a row is, and which of its sentences the reader has to read.
  #
  # The defect these are written against: the pill keyed off `warnings.any?`,
  # so a Livret A carrying "interest is taxed as it arises" -- true forever,
  # asking nobody for anything -- rendered the same amber as a wrapper missing
  # the one figure that would let it be computed. Six rows in eight came out
  # amber, which is the same information as none of them coming out amber.
  #
  # Built from Tax::Result directly rather than through the engine. The subject
  # here is the page's reading of a result, and going through a rule would make
  # each of these depend on that rule continuing to emit the particular
  # sentence the test picked -- a failure in a file that has nothing to do with
  # what broke.
  class StatusPillTest < ActionView::TestCase
    tests TaxReportsHelper

    def result_with(*keys, tax: BigDecimal(10), reviewed: false, modelled: true)
      Result.new(
        account_id: "x", account_name: "An account", currency: "EUR",
        gross: BigDecimal(100), tax: tax, modelled: modelled,
        reviewed: reviewed,
        warnings: keys.map { |key| Message.new(key) }
      )
    end

    def label(result) = tax_status_pill(result).first

    # Asserted on the tone and the glyph rather than on a class string, which
    # is what these two used to compare. The helper now hands DS::Pill a tone
    # and lets the component decide what that looks like, so a class string
    # here would be asserting the component's implementation from a test about
    # the report -- and would fail the day DS::Pill changed a shade, having
    # caught nothing. The tone is the decision this module makes; the classes
    # were never ours.
    def tone_and_glyph(result) = tax_status_pill(result).drop(1)

    test "a computed row carrying only notes is green" do
      result = result_with("fr_deposit.note_interest_taxed_as_it_arises",
                           "fr_securities.flat_tax_assumed")

      assert_equal I18n.t("tax_reports.show.status.computed"), label(result)
      assert_equal [ :success, "check" ], tone_and_glyph(result)
    end

    test "a computed row missing a figure the form collects is amber" do
      result = result_with("fr_capital_and_gains.no_deducted")

      assert_equal I18n.t("tax_reports.show.status.incomplete"), label(result)
    end

    # Grey, not amber. Amber says *you have something to fix*; an account whose
    # product this module has no rule for is the module's limitation, and the
    # reader has nothing to fix. The old helper said exactly this in a comment
    # and then used amber anyway.
    test "a row with no number at all is grey rather than amber" do
      result = result_with("unknown.no_rule", tax: nil, modelled: false)

      assert_equal I18n.t("tax_reports.show.status.not_computed"), label(result)
      # A dash, not a cross. The glyph carries the same three-way distinction
      # as the tone for a reader who cannot see the tone, and a cross would say
      # "rejected" about a row where nothing was rejected -- the same claim the
      # grey makes, made again in the one part of the pill that survives a
      # monochrome screen.
      assert_equal [ :neutral, "minus" ], tone_and_glyph(result)
    end

    test "notes are separated from the sentences that ask for something" do
      result = result_with("fr_capital_and_gains.no_deducted",
                           "fr_capital_and_gains.whole_wrapper_lump_sum")

      warnings = tax_warnings(result)

      assert_equal 1, warnings[:gap].size
      assert_equal 1, warnings[:note].size
    end

    # `reviewed_at` was written on every save and read by nothing, which is why
    # "à vérifier" never went away after you had verified. Opening the form and
    # saving it is an answer to the question the form asked.
    test "a gap about a box you looked at and left empty goes quiet once saved" do
      key = "fr_capital_and_gains.no_deducted"

      assert_equal :gap, tax_warnings(result_with(key)).keys.first
      assert_equal :note,
                   tax_warnings(result_with(key, reviewed: true)).keys.first
    end

    test "and the row goes green with it, because there is nothing left to ask" do
      result = result_with("fr_capital_and_gains.no_deducted", reviewed: true)

      assert_equal I18n.t("tax_reports.show.status.computed"), label(result)
    end

    # The exception, and the reason the demotion is keyed on a fact rather than
    # on the severity alone. A marginal rate is the household's, not the
    # account's, and no per-account form ever offered it -- so saving that form
    # is not an answer and must not read as one.
    test "a gap no account form could close is not quietened by saving one" do
      result = result_with("assumptions.marginal_rate_caveat", reviewed: true)

      assert_equal I18n.t("tax_reports.show.status.incomplete"), label(result)
    end

    # Rules::Composed carries the free text a household typed into its own
    # custom rule, as a String rather than a Message. It has no key, so it has
    # no severity to look up.
    test "a household's own words about their own rule are a note" do
      result = Result.new(
        account_id: "x", account_name: "An account", currency: "EUR",
        gross: BigDecimal(100), tax: BigDecimal(10),
        warnings: [ "Rule copied from my accountant's note" ]
      )

      assert_equal [ :note ], tax_warnings(result).keys
      assert_equal I18n.t("tax_reports.show.status.computed"), label(result)
    end
  end

  # Which of the four things a row's link says, if it says anything.
  #
  # The pill above answers "how much attention does this row want"; this
  # answers "and what would I do about it", and the two are not the same
  # question. A row can be amber and have nothing a form could fix -- an unset
  # household marginal rate lives on another screen entirely -- and a row can
  # be green and still be worth opening, which is why "Adjust" exists at all.
  #
  # Built from Tax::Result rather than through the engine for the reason given
  # above StatusPillTest: the subject is the page's reading, and routing each
  # of these through a rule would make them fail whenever that rule changed
  # which sentence it emits.
  class ProfileActionTest < ActionView::TestCase
    tests TaxReportsHelper

    def result_with(*keys, account_id: "x", missing: [], modelled: true,
                    reviewed: false)
      Result.new(
        account_id: account_id, account_name: "An account", currency: "EUR",
        gross: BigDecimal(100), tax: modelled ? BigDecimal(10) : nil,
        modelled: modelled, missing_facts: missing, reviewed: reviewed,
        warnings: keys.map { |key| Message.new(key) }
      )
    end

    def action(result) = tax_profile_action(result)&.first

    # The state Part 4 brought into existence. Before it this account had no
    # number and said "Declare"; now it has one, and what it wants is not the
    # same thing. The label has to move with the figure or the page is telling
    # a reader that nothing was computed while showing them what was.
    test "a figure reached from a stand-in asks to be refined, not declared" do
      result = result_with("fr_pea.computed_from_cost_basis")

      assert_equal I18n.t("tax_reports.show.refine"), action(result)
    end

    # The reason tax_profile_action takes the demoted warnings rather than
    # calling warnings_by_severity itself. Without this the pill would go green
    # on a saved row while the link beside it went on asking for the same box,
    # and a page that contradicts itself in two adjacent columns is worse than
    # one that is merely wrong.
    test "and stops asking once the household has looked at the box" do
      result = result_with("fr_pea.computed_from_cost_basis", reviewed: true)

      assert_equal I18n.t("tax_reports.show.adjust"), action(result)
    end

    test "a refusal a fact would lift asks for that fact" do
      result = result_with("fr_capital_and_gains.no_paid_in",
                           missing: [ :paid_in ], modelled: false)

      assert_equal I18n.t("tax_reports.show.declare"), action(result)
    end

    # Amber, and yet there is nothing to refine here: the marginal rate is the
    # household's and no per-account form has ever offered it. Offering
    # "Refine" would send a reader to a form that cannot contain their problem.
    test "a gap naming no box the form holds does not ask for one" do
      result = result_with("assumptions.marginal_rate_caveat")

      assert_equal I18n.t("tax_reports.show.adjust"), action(result)
    end

    # `:cost_basis` is derived from Sure's own holdings and collected by no
    # form, so it appears in missing_facts and must not produce a link. This is
    # the case the old `missing_facts.any?` test got wrong: it offered
    # "Declare" on a row where declaring was impossible.
    test "a refusal no form could lift offers nothing at all" do
      result = result_with("fr_securities.no_cost_basis",
                           missing: [ :cost_basis ], modelled: false)

      assert_nil tax_profile_action(result)
    end

    # The totals row, and the coverage rows for products nobody holds. No
    # account behind them, so no form to link to.
    test "a row with no account behind it offers nothing" do
      result = result_with(account_id: nil)

      assert_nil tax_profile_action(result)
    end
  end

  # The half-line under the rule name saying which figure the gain was measured
  # against.
  #
  # Small enough to look untestable and worth testing for exactly one reason:
  # the symbol comes from a rule, and the lookup must not interpolate it into an
  # i18n key. A rule that one day sets `basis_source: :versements` should print
  # nothing rather than `translation missing: ...show.source.versements` in the
  # middle of somebody's tax figures.
  class BasisSourceLineTest < ActionView::TestCase
    tests TaxReportsHelper

    def result_with(source)
      Result.new(account_name: "An account", gross: BigDecimal(100),
                 currency: "EUR", basis_source: source)
    end

    test "a gain measured against declared payments says so" do
      assert_equal I18n.t("tax_reports.show.source.paid_in"),
                   tax_basis_source(result_with(:paid_in))
    end

    test "a gain measured against the holdings says so" do
      assert_equal I18n.t("tax_reports.show.source.cost_basis"),
                   tax_basis_source(result_with(:cost_basis))
    end

    # A rule that never went through the cascade -- one written entirely in
    # `paid_in` terms, or one for a product where the question does not arise --
    # leaves this nil, and nil must print nothing rather than a caption
    # qualifying a method it did not use.
    test "a rule with no cascade behind it says nothing" do
      assert_nil tax_basis_source(result_with(nil))
    end

    test "a source this page has no words for prints nothing, not a key" do
      assert_nil tax_basis_source(result_with(:something_a_future_rule_sets))
    end
  end

  # Which of the three blocks a row lands in.
  #
  # The states themselves are already covered by StatusPillTest above; what is
  # tested here is that the two agree, because the whole reason `tax_row_state`
  # exists as its own method is that a row's colour and a row's block are one
  # decision. A copy of the conditions that drifted would file a row under
  # "needs something from you" and paint it green.
  class RowStateTest < ActionView::TestCase
    tests TaxReportsHelper

    def result_with(*keys, modelled: true, reviewed: false)
      Result.new(
        account_id: "x", account_name: "An account", currency: "EUR",
        gross: BigDecimal(100), tax: modelled ? BigDecimal(10) : nil,
        modelled: modelled, reviewed: reviewed,
        warnings: keys.map { |key| Message.new(key) }
      )
    end

    test "no figure means the last block, whatever else is true of the row" do
      result = result_with("fr_securities.no_cost_basis", modelled: false)

      assert_equal :not_computed, tax_row_state(result)
    end

    test "a surviving gap means the first block" do
      result = result_with("fr_pea.computed_from_cost_basis")

      assert_equal :incomplete, tax_row_state(result)
    end

    test "a gap the household has already answered does not" do
      result = result_with("fr_pea.computed_from_cost_basis", reviewed: true)

      assert_equal :computed, tax_row_state(result)
    end

    test "notes alone leave a row computed" do
      result = result_with("fr_securities.flat_tax_assumed")

      assert_equal :computed, tax_row_state(result)
    end

    test "every state the grouping iterates is one a row can actually be in" do
      states = [
        result_with("fr_securities.no_cost_basis", modelled: false),
        result_with("fr_pea.computed_from_cost_basis"),
        result_with
      ].map { |result| tax_row_state(result) }

      assert_equal TaxReportsHelper::STATES.to_set, states.to_set
    end

    # The pill and the block are read off the same answer, so a row cannot be
    # sorted into one state and painted as another. Asserted rather than assumed
    # because the pill used to own these conditions outright.
    test "the pill agrees with the block for every state" do
      {
        result_with("fr_securities.no_cost_basis", modelled: false) => "not_computed",
        result_with("fr_pea.computed_from_cost_basis") => "incomplete",
        result_with => "computed"
      }.each do |result, state|
        assert_equal state.to_sym, tax_row_state(result)
        assert_equal I18n.t("tax_reports.show.status.#{state}"),
                     tax_status_pill(result).first
      end
    end
  end
end
