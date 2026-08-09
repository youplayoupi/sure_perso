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
            { "base" => "paid_in_deducted", "rate" => "progressive" },
            { "base" => "gain_over_paid_in", "rate" => "flat_tax" }
          ]
        }
      )

      assert rule.valid?, rule.errors.full_messages.inspect
      assert rule.composed?
      assert_instance_of Rules::Composed, rule.to_rule
      assert_equal 2, rule.formula.terms.length
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

    test "cost basis is nil rather than a partial sum when a holding is missing one" do
      account = accounts(:investment)
      account.holdings.update_all(cost_basis: nil)

      subject = SubjectBuilder.new(@family).subjects.find { |s| s.id == account.id }

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
end
