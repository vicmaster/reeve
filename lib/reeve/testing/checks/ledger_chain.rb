# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # Whether the ledger's chain holds (specs/002 FR-018).
      #
      # It writes entries of its own first — the first compliance tool, once per fixture
      # principal — because a suite with transactional fixtures starts every example with
      # an empty ledger, and a check that only looked would find nothing and say nothing.
      # Then it verifies the whole ledger the run can see, not only its own rows: a break an
      # earlier run left behind is reported, not hidden.
      #
      # * **intact** — passed; the message is the verification's own summary line, so it
      #   states the range covered and what was not.
      # * **broken, unverifiable, or no chain after writing** — failed. The run signed its own
      #   entries, so a key it lacks or a recorder that did not chain is a configuration
      #   error, not an absence.
      # * **no key configured** — failed, naming the setting.
      # * **nothing to write or read** (no compliance tools, ledger not loaded) — skipped,
      #   saying the chain was not verified. Never passed.
      #
      #   Reeve::Checks::LedgerChain.new.call
      class LedgerChain < Base
        NOT_VERIFIED = "the ledger chain was not verified"

        def initialize(tools: nil, principals: nil, arguments: {}, invoke: nil, ledger: nil)
          @tools = tools
          @principals = principals
          super(tool: nil, arguments: arguments, invoke: invoke, ledger: ledger)
        end

        def call
          return skipped("there is no compliance tool to write an entry with") if subject.nil?
          return skipped(unreadable_reason) unless readable?
          return no_key if Reeve.config.ledger_key.nil?

          unwritten = write_entries
          return unwritten_entry(unwritten) if unwritten

          judge(ledger.verify_chain)
        end

        private

        def subject
          @subject ||= Array(@tools || Testing.compliance_tools).first
        end

        def principals
          configured = Testing.compliance_principals? ? Testing.compliance_principals : nil
          list = Array(@principals || configured)
          list.empty? ? [nil] : list
        end

        # Each principal on its own, so one refusal does not stop the next. A denial, or the
        # tool's own error, still leaves a ledger entry — the envelope records before it
        # re-raises — which is all this needs. A failed ledger write leaves none, and is
        # returned as the reason the chain could not be checked.
        #
        # Returns nil when entries were written, or the reason none were — including the case
        # where every invocation failed before reaching reeve, which a chain left by an
        # earlier run must not be allowed to pass for.
        def write_entries
          before = ledger.count
          principals.each do |principal|
            invoke.call(tool: subject, arguments: arguments, principal: principal)
          rescue Reeve::AuditWriteError => e
            return "#{e.class}: #{e.message}"
          rescue StandardError
            next
          end
          ledger.count == before ? "its invocations wrote no entry" : nil
        end

        def readable?
          ledger.available? && ledger.respond_to?(:verify_chain)
        end

        def unwritten_entry(reason)
          failed("#{NOT_VERIFIED}: it wrote no entry of its own — #{reason}",
                 coverage: :unwritten)
        end

        def unreadable_reason
          ledger.unavailable_reason || "this ledger cannot verify a chain"
        end

        def judge(verification)
          return skipped("the audit ledger is not loaded") if verification.nil?

          summary = verification.to_s
          return passed(summary.lines.first.chomp, coverage: :intact) if verification.intact?

          failed(summary, coverage: verification.status)
        end

        def no_key
          failed("expected the ledger to be chained, but no ledger key is configured: set " \
                 "config.ledger_key (the generated initializer derives one from secret_key_base)",
                 coverage: :no_key)
        end

        # Every skip says, first, that the chain was not verified — then why.
        def skipped(reason)
          Result.skipped(check: check_name, message: "#{NOT_VERIFIED}: #{reason}",
                         details: { coverage: :unverified })
        end

        def base_details
          {}
        end
      end
    end
  end
end
