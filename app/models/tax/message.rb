# frozen_string_literal: true

module Tax
  # A sentence the engine wants to say, named rather than spelled out.
  #
  # Every warning, every refusal and every `basis` line used to be an English
  # string built where it was raised. That read well -- the sentence sat beside
  # the arithmetic it described -- and it made the module untranslatable in
  # principle rather than merely untranslated: there was no list of what the
  # report could say, so there was nothing for a translator to be handed.
  #
  # A Message is the key and the values, and nothing else. The English lives in
  # Tax::Messages, the translations live in the locale files, and the engine
  # never learns which language it is being read in. That last part is load
  # bearing: the engine is required into a bare Ruby process by
  # test/models/tax/engine_test.rb with nothing but bigdecimal, date and yaml,
  # precisely so a dependency on the framework cannot creep into the
  # arithmetic. `I18n.t` inside a rule would end that on the day it was written.
  #
  # So `to_s` renders the English, which is what the bare process and the
  # crosscheck script need, and TaxReportsHelper#tax_message renders the
  # reader's language, which is what a page needs. Neither is the engine's
  # business.
  class Message
    attr_reader :key, :args

    def initialize(key, args = {})
      @key = key.to_s
      # Symbol keys because that is what both interpolators want: Ruby's
      # `String#%` and I18n both look the placeholder up by symbol.
      @args = args.to_h { |name, value| [ name.to_sym, value ] }.freeze
      freeze
    end

    # A run of items that becomes one phrase, and the word that joins them.
    #
    # Vocabulary.to_sentence joined with "and" and nothing else, which was fine
    # while the only list in the module was a list of missing facts.
    # Rules::Composed joins the lines of its calculation with "plus" -- a
    # different word, in English and in every other language -- and hardcoding
    # either of them inside the renderer leaves an untranslated English word
    # sitting in the middle of a translated sentence, which is the exact defect
    # this whole mechanism exists to remove.
    #
    # So the connector travels with the list, as a key like any other. A
    # translator is handed `connectors.plus` alongside the sentences it appears
    # in, rather than finding out it was missing from a French report.
    class List
      attr_reader :items, :connector

      # A nil connector joins with commas and nothing else. That is not a list
      # of things -- it is one clause narrowed by the next, "31.4% flat tax on
      # the gain, once the account is 5 years old" -- and putting "and" in
      # there would turn one statement into two.
      def initialize(items, connector: "and")
        @items = Array(items).freeze
        @connector = connector&.to_s
        freeze
      end

      def to_s
        Messages.render_list(self)
      end
    end

    # The vocabulary namespaces are shared with the select menus on the rules
    # screen, which look them up directly. A base named one way in a dropdown
    # and another way in the warning that refuses it would read as two
    # different quantities; pointing both at one key is what stops that.
    VOCABULARY = %w[bases rates facts connectors treatments].freeze

    def to_s
      Messages.render(@key, @args)
    end

    # What this sentence asks of the reader, and which fact it asks for.
    #
    # Both are looked up from the key rather than carried on the instance, so
    # the constructor keeps its two arguments and none of the ~60 places that
    # raise a message has to say anything new. Tax::Messages::SEVERITY explains
    # why that is the right shape and not merely the cheap one.
    def severity
      Messages.severity(key)
    end

    def asks_for
      Messages.asks_for(key)
    end

    # Where a translator finds this sentence. Computed here rather than at the
    # view edge so that the engine owns its own naming and the helper stays a
    # lookup.
    def i18n_key
      VOCABULARY.include?(key.split(".").first) ? "tax.#{key}" : "tax.messages.#{key}"
    end

    # Two messages are the same message when they would render the same way in
    # every language, which is to say when the key and the values agree.
    # Identity comparison would be the wrong answer for a value object and the
    # kind of wrong answer that only shows up once something tries to dedupe a
    # warning list -- by which point the cause is a long way from the symptom.
    def ==(other)
      other.is_a?(Message) && other.key == key && other.args == args
    end
    alias_method :eql?, :==

    def hash
      [ key, args ].hash
    end

    def inspect
      "#<Tax::Message #{key} #{args.inspect}>"
    end
  end
end
