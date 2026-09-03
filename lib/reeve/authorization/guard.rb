# frozen_string_literal: true

module Reeve
  # The tool-side surface: two macros and one helper. `include Reeve::Guard` in a tool
  # class (the fast-mcp adapter does it for you) and declare which policy governs it.
  #
  #   class InvoiceSearchTool
  #     include Reeve::Guard
  #     guard_with InvoicePolicy
  #     redact :customer_ssn
  #
  #     def call(query:)
  #       Invoice.where("number LIKE ?", "%#{query}%")
  #     end
  #   end
  module Guard
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Class-level DSL. See contracts/tool-dsl.md.
    module ClassMethods
      # Declares which policy governs this tool. Absence is not neutral: a tool with no
      # declaration is denied by the envelope (FR-002, FR-004).
      def guard_with(policy, action: nil)
        Authorization::Adapter.validate!(policy)

        @reeve_guard = Reeve.registry.register(
          tool_class: self,
          policy: policy,
          action: action,
          redacted_arguments: pending_redactions + inherited_redactions
        )
      end

      # Argument names this tool never writes to the ledger in the clear, on top of the
      # process-wide list (FR-011).
      def redact(*names)
        symbols = names.flatten.map(&:to_sym)
        @pending_redactions = pending_redactions | symbols

        declaration = reeve_guard
        return symbols if declaration.nil?

        @reeve_guard = Reeve.registry.add(
          declaration.with(redacted_arguments: declaration.redacted_arguments | symbols)
        )
        symbols
      end

      # This tool's declaration, inherited from a superclass when it has none of its own.
      def reeve_guard
        Reeve.registry.for_class(self)
      end

      def guarded?
        !reeve_guard.nil?
      end

      # A subclass of a guarded tool is itself guarded, and is registered under its own
      # name so the envelope — which only ever has a name — can find it.
      def inherited(subclass)
        super
        declaration = reeve_guard
        # An anonymous subclass has no name to be looked up by; it still inherits the
        # declaration through the ancestry walk in Registry#for_class.
        return if declaration.nil? || subclass.name.nil?

        Reeve.registry.add(declaration.for_subclass(subclass))
      end

      def pending_redactions
        @pending_redactions ||= []
      end

      private

      def inherited_redactions
        return [] unless superclass.respond_to?(:reeve_guard)

        inherited = superclass.reeve_guard
        inherited ? inherited.redacted_arguments : []
      end
    end

    # The scoped relation for the invoking principal. This is how a guarded tool returns
    # anything that is not a record: a count, a sum, a rendered summary. Computing from
    # `scoped(...)` means the tool never held unscoped data, so the derived value is safe
    # by construction rather than by promise (R4).
    def scoped(model_or_relation)
      state = Authorization::Current.state
      raise Error, "scoped(...) may only be called inside a guarded invocation" if state.nil?

      Authorization::Scoper.scoped_relation(state, model_or_relation)
    end

    # Asks the declared policy about one record, before the tool acts on it. Returns the
    # record so it reads inline; raises +DeniedError+ if the policy says no.
    #
    #   def call(id:, to:)
    #     lead = authorize!(Lead.find(id))
    #     Mailer.introduction(lead, to).deliver_now
    #     lead
    #   end
    #
    # The envelope authorizes before the tool runs and scopes what it returns, and between
    # those two points a tool can do things neither of them can reach. A rolled-back write
    # leaves no trace; a sent email does. `scoped(...)` is the answer when a tool can work
    # from a relation; this is the answer when it cannot — when the tool holds one record
    # and is about to do something to the world with it.
    #
    # The denial carries the policy's own rule, so the ledger names what refused rather
    # than reporting the tool as broken. It names no record: an out-of-scope record and a
    # record that does not exist have to be indistinguishable (FR-006), and a tool that
    # reached this line has already fetched the record it must not talk about.
    def authorize!(record)
      state = Authorization::Current.state
      raise Error, "authorize!(...) may only be called inside a guarded invocation" if state.nil?

      decision = state.adapter.authorize(
        principal: state.context.principal, policy: state.declaration.policy,
        action: state.declaration.action, record: record
      )
      return record if decision.allowed?

      raise DeniedError.from(decision, tool_name: state.context.tool_name,
                                       principal_id: state.context.principal_id)
    end
  end
end
