# frozen_string_literal: true

# Loads the rule engine with or without Rails, whichever is already there.
#
# Under `bin/rails test` the autoloader has done the work and this file adds
# nothing but the fake below. Run as `ruby test/models/tax/engine_test.rb` and
# it requires the same classes by hand, in dependency order, against a bare
# Ruby.
#
# The double life is the point. The engine is a set of pure functions over
# value objects, and a suite that can only run inside a booted Rails app would
# quietly let a dependency on the framework creep in -- an `ActiveSupport`
# refinement here, a `Rails.root` there -- until the arithmetic could no longer
# be diffed against the Python reference implementation. Requiring the files
# into an empty process is the check that keeps them honest, and it fails
# loudly the moment something reaches for Rails.
# Minitest is deliberately *not* required here. `crosscheck.rb` loads this
# helper to print a table, not to assert anything, and pulling in autorun would
# staple a "0 runs, 0 assertions" banner onto output that gets diffed.
require "bigdecimal"
require "bigdecimal/util"
require "date"
require "yaml"

module TaxEngineTestHelper
  ROOT = File.expand_path("../../..", __dir__)

  # Ordered because these are plain `require`s, not autoloads: a rule class
  # that inherits from Rules::Base has to see Rules::Base first.
  ENGINE = %w[
    tax
    tax/vocabulary
    tax/rate_table
    tax/rate_overlay
    tax/rate_edit
    tax/assumptions
    tax/subject
    tax/result
    tax/treatment
    tax/formula
    tax/formula_presenter
    tax/rules/base
    tax/rules/composed
    tax/rules/unknown
    tax/rules/exempt
    tax/rules/not_modelled
    tax/rules/fr/pea
    tax/rules/fr/securities
    tax/rules/fr/deposit
    tax/rules/fr/capital_and_gains
    tax/catalogue
    tax/registry
    tax/snapshot
    tax/projection
  ].freeze

  def self.rails?
    defined?(Rails) && Rails.respond_to?(:root)
  end

  def self.load_engine!
    return if rails?

    ENGINE.each { |name| require File.join(ROOT, "app", "models", "#{name}.rb") }
  end

  # `Tax.config_dir` calls `Rails.root`, so outside Rails the tests point at
  # the YAML directly. Same file either way -- the rates under test are the
  # rates that ship.
  def self.rate_file(country = "FR")
    File.join(ROOT, "config", "tax", "#{country.downcase}.yml")
  end

  # Stands in for the `TaxCustomRule` record that has not been written yet.
  # Registry only ever asks a custom rule four things, and this answers them.
  # Keeping the fake this thin means the eventual model has to stay that thin
  # too, or the tests stop describing it.
  class FakeCustomRule
    attr_reader :accountable_type, :subtype, :account_id

    def initialize(rule:, accountable_type: nil, subtype: nil, account_id: nil)
      @rule = rule
      @accountable_type = accountable_type
      @subtype = subtype
      @account_id = account_id
    end

    def to_rule = @rule
  end
end

TaxEngineTestHelper.load_engine!
