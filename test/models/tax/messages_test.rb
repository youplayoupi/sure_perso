# frozen_string_literal: true

require "test_helper"

# Every sentence the engine can say, checked against every language it claims
# to speak.
#
# This is the test that makes the whole Tax::Message detour worth its cost. The
# module used to build its warnings as English string literals where they were
# raised, which read beautifully and was untranslatable in principle rather
# than merely untranslated: there was no list of what the report could say, so
# there was nothing a translator could be handed and nothing a build could
# check. Now there is a list, and this walks it.
#
# It runs under Rails rather than in the bare process the rest of the engine is
# tested in, because it is the only tax test whose subject is the locale files.
class Tax::MessagesTest < ActiveSupport::TestCase
  # The languages this module promises. English is not in it: the engine's own
  # Ruby *is* the English, which is what `default:` falls back to at the view
  # edge, and a second copy in en.yml would be a second copy that drifts.
  TRANSLATED = %w[fr].freeze

  test "every message the engine can emit renders in English" do
    Tax::Messages.keys.each do |key|
      # Placeholders are filled with their own names. What is under test is
      # that the key resolves at all -- to a sentence in TEXTS or to a word in
      # Tax::Vocabulary -- not what it says.
      #
      # The hash is built from the template rather than defaulted, because
      # Ruby's `String#%` fetches each key and a default proc never runs: a
      # message whose template asks for a value the caller did not supply is a
      # bug, and this file is not the place to paper over it.
      text = Tax::Messages::TEXTS[key]
      args = placeholders(text.to_s).to_h { |name| [ name.to_sym, name ] }

      rendered = Tax::Messages.render(key, args)

      assert_predicate rendered.to_s, :present?, "#{key} renders as nothing"
    end
  end

  test "every message is translated in every language this module claims" do
    TRANSLATED.each do |locale|
      missing = Tax::Messages.keys.reject { |key| translated?(locale, key) }

      assert_empty missing, <<~MESSAGE
        #{missing.size} tax message(s) have no #{locale} translation.

        Add them under `tax.messages` (or the matching vocabulary namespace) in
        config/locales/views/tax_reports/#{locale}.yml. Until then a
        #{locale} reader gets these sentences in English, in the middle of an
        otherwise translated report, and nothing else tells anybody.

        #{missing.sort.join("\n")}
      MESSAGE
    end
  end

  # A translation that drops a placeholder is worse than no translation: the
  # English says "exceeds the 22950 ceiling" and the French silently says
  # "exceeds the ceiling", with no number and no error. I18n only raises for a
  # placeholder it cannot fill, never for one the translator left out.
  test "every translation uses the same placeholders as the English" do
    TRANSLATED.each do |locale|
      Tax::Messages::TEXTS.each do |key, english|
        translated = I18n.t("tax.messages.#{key}", locale: locale, default: nil)
        next if translated.nil?

        assert_equal placeholders(english), placeholders(translated),
                     "tax.messages.#{key} in #{locale} does not use the same values as the English"
      end
    end
  end

  # The one interpolation hazard this scheme has. Ruby's `String#%` reads `%%`
  # as an escaped percent and I18n leaves it alone, so a template carrying one
  # renders differently depending on which of the two got to it -- English and
  # French disagreeing about a tax rate, for no reason a reader could diagnose.
  # Percentages therefore arrive already formatted from Rules::Base#percent,
  # and no template may contain a bare percent sign at all.
  test "no template contains a literal percent sign" do
    offenders = Tax::Messages::TEXTS.select { |_key, text| text.match?(/%(?!\{)/) }.keys

    assert_empty offenders,
                 "these templates carry a literal %, which renders differently in " \
                 "Ruby and in I18n: #{offenders.join(', ')}"

    TRANSLATED.each do |locale|
      bad = Tax::Messages::TEXTS.keys.select do |key|
        text = I18n.t("tax.messages.#{key}", locale: locale, default: nil)
        text&.match?(/%(?!\{)/)
      end

      assert_empty bad, "#{locale} translations carrying a literal %: #{bad.join(', ')}"
    end
  end

  # The same shape as the parity test above, and there for the same reason.
  #
  # `Messages.severity` defaults to `:note`, so nothing breaks when a key is
  # missing from the table -- it just quietly joins the pile of sentences the
  # page shows least prominently. A refusal that landed there would be a row
  # printing "not computed" with the reason folded away behind a disclosure,
  # which is precisely the failure this whole part exists to fix, arriving by
  # omission instead of by design.
  #
  # So the default is for robustness at runtime and this is the thing that
  # stops anybody relying on it: a key added without a decision fails here,
  # while its author is still holding the reason.
  test "every message the engine can emit has a declared severity" do
    undeclared = Tax::Messages::TEXTS.keys - Tax::Messages::SEVERITY.keys

    assert_empty undeclared, <<~MESSAGE
      #{undeclared.size} tax message(s) have no entry in Tax::Messages::SEVERITY.

      Decide what each one asks of the reader -- :note, :gap or :blocker -- and
      say so there. Left out, they default to :note, which puts them behind the
      "n notes" disclosure on the report.

      #{undeclared.sort.join("\n")}
    MESSAGE
  end

  # The other direction. A key removed from TEXTS -- Part 3 removed several --
  # leaves a line in SEVERITY that reads like a decision about a sentence
  # nobody can see any more.
  test "no severity is declared for a message that no longer exists" do
    orphans = Tax::Messages::SEVERITY.keys - Tax::Messages::TEXTS.keys

    assert_empty orphans,
                 "these keys have a severity but no English: #{orphans.join(', ')}"
  end

  test "every fact a gap asks for is one the account form actually offers" do
    Tax::Messages::ASKS_FOR.each do |key, fact|
      assert_equal :gap, Tax::Messages.severity(key),
                   "#{key} names a fact to declare but is not a gap"
      # The demotion in TaxReportsHelper#tax_severity intersects against this
      # list, so a fact outside it would be an entry that never does anything
      # -- and would look, to the next reader, like a demotion that was
      # supposed to happen and did not.
      assert_includes Tax::Profile::DECLARABLE, fact,
                      "#{key} asks for #{fact}, which no account form collects"
    end
  end

  private
    def translated?(locale, key)
      namespace = key.split(".").first
      scope = Tax::Message::VOCABULARY.include?(namespace) ? "tax" : "tax.messages"

      I18n.t("#{scope}.#{key}", locale: locale, default: nil).present?
    end

    def placeholders(text)
      text.scan(/%\{(\w+)\}/).flatten.sort
    end
end
