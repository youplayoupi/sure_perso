# frozen_string_literal: true

module Tax
  # Declaring the facts Sure has nowhere to store, one account at a time.
  #
  # The only writing this module does, and it writes to its own table only.
  class ProfilesController < ApplicationController
    before_action :set_account
    before_action :set_profile
    before_action :set_relevant_facts

    def edit
    end

    def update
      # Clearing after the declared values rather than before, so that a form
      # which both sets a figure and asks to clear it resolves to cleared. That
      # combination should not arise -- a fact is offered as an input or as a
      # value to remove, never both -- and if it ever does, removing is the
      # answer that cannot leave a stale number behind.
      attributes = profile_params.merge(cleared_facts).merge(reviewed_at: Time.current)

      if @profile.update(attributes)
        redirect_to tax_report_path, notice: t(".saved", account: @account.name)
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private
      # Scoped through the family, so a profile can only ever be attached to an
      # account the current user can already see.
      def set_account
        @account = Current.family.accounts.find(params[:account_id])
      end

      # Loaded before the facts are worked out rather than inside each action,
      # because which fields the form shows now depends on which of them
      # already hold a figure. See `stale_facts`.
      def set_profile
        @profile = Profile.find_or_initialize_by(account_id: @account.id)
      end

      # Blanking a figure the current rule has no use for.
      #
      # A checkbox rather than a link, so that removing a value goes through
      # the same submit as changing one -- one request, one `reviewed_at`, and
      # no second route that writes to this table. The names are checked
      # against DECLARABLE rather than trusted, since they arrive as strings
      # from a form and end up as attribute names.
      def cleared_facts
        names = Array(params[:clear_facts]).map(&:to_sym) & Profile::DECLARABLE

        names.index_with { nil }
      end

      # Which of the four declarable facts this account's rule has any use for.
      #
      # The form used to ask for all of them on every account, which made it
      # look like the module wanted four figures from a Livret A when it wanted
      # none, and left a reader with no way to tell the question that mattered
      # from the three that did not. A rule already says what it wants -- see
      # Tax::Formula#needs and #optional_needs -- so the form can ask that
      # instead of guessing.
      #
      # `opened_on` is deliberately not subtracted when Sure has a date of its
      # own. It was, while the rest of the fields lived on in a disclosure
      # underneath; with that gone the subtraction would leave no way at all to
      # correct Sure's answer, and Sure's answer is a balance's starting point
      # rather than the date of the first payment in, which is what the clocks
      # actually run from. The field is offered and says what Sure has --
      # see the fact partial.
      def set_relevant_facts
        formula = resolved_rule&.formula

        wanted = if formula.nil?
          # No formula means no arithmetic -- Rules::Unknown and
          # Rules::NotModelled -- so there is no fact whose absence is the
          # problem. Asking for one would imply this account is a form away
          # from a number, and it is not.
          []
        else
          ([ :product ] + formula.needs + formula.optional_needs) & Profile::DECLARABLE
        end

        @relevant_facts = Profile::DECLARABLE & wanted
        @stale_facts = stale_facts
        @rule_id = resolved_rule&.class&.rule_id
        @sure_opening_date = sure_opening_date
        @sure_known_since = sure_known_since
      end

      # Facts this rule does not read but which already hold a figure.
      #
      # These used to be the contents of a disclosure holding all four fields,
      # rendered as inputs. That was worse than it looked: three empty boxes
      # behind a summary, offering to collect figures no rule would read, on
      # every account. What it was protecting is the narrow real case -- the
      # rule attached to an account can be changed on the Taxes screen, and a
      # figure typed under the old one should not silently keep affecting
      # nothing while being invisible.
      #
      # So the case is kept and the boxes are not. A value with no rule to read
      # it is shown as what it is, with the means to remove it, and nothing is
      # offered where there is nothing to show.
      def stale_facts
        (Profile::DECLARABLE - @relevant_facts).select do |fact|
          @profile.public_send(fact).present?
        end
      end

      # The rule that will actually run against this account, resolved the same
      # way the report resolves it -- through a Subject, so that a custom rule
      # pinned to the account is honoured here too. A Tax::Error means there is
      # no rate file for this country, so nothing can be said about which facts
      # matter; the form then asks for none of them, which is the same shape as
      # an account with no arithmetic behind it.
      def resolved_rule
        return @resolved_rule if defined?(@resolved_rule)

        @resolved_rule = subject && builder.registry.resolve(subject)
      rescue Tax::Error
        @resolved_rule = nil
      end

      def builder
        @builder ||= SubjectBuilder.new(Current.family, accounts: [ @account ])
      end

      def subject
        return @subject if defined?(@subject)

        @subject = builder.subjects.first
      end

      # Sure's own opening date, and only when it is one.
      #
      # Read off the Subject rather than off the account, which is the point of
      # the change. This used to re-implement the anchor test -- "is there an
      # anchor row" -- beside Tax::SubjectBuilder's copy of the same question,
      # and the two then had to be corrected in step when that test turned out
      # to be wrong. One of them is the module's answer; this asks it.
      #
      # nil when the household declared a date of their own, because the
      # sentence this drives says Sure's date "is the date used", and once
      # there is an override that is no longer true.
      def sure_opening_date
        return nil if subject.nil?
        return nil if subject.declared.include?(:opened_on)

        subject.opened_on
      end

      # The weaker fact, carried separately for the same reason the engine
      # carries it separately: a floor is not a date, and a form that showed
      # them in the same sentence would be inviting the reader to type one in
      # as though it were the other.
      def sure_known_since
        subject&.known_since
      end

      def profile_params
        params.require(:tax_profile)
              .permit(:product, :opened_on, :paid_in, :paid_in_deducted, :notes)
      end
  end
end
