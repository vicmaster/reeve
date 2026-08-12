# frozen_string_literal: true

require_relative "ledger"

# Drives a real invocation through the frozen kernel with the ledger wired in.
#
# The audit module's guarantees are about what the envelope leaves behind, so the audit
# specs assert on rows produced by an actual `Reeve::Invocation.call` rather than on a
# recorder poked by hand. The authorization collaborators are the kernel doubles from
# spec/support — W2 does not depend on W1.
module Envelope
  Principal = Struct.new(:id)
  Guard = Struct.new(:redacted_arguments)

  DEFAULT_AGENT = { id: "claude-desktop", name: "Claude Desktop" }.freeze

  def invoke(tool_name: "InvoiceSearchTool",
             principal: Principal.new(7),
             arguments: {},
             agent: DEFAULT_AGENT,
             decision: nil,
             scope_result: nil,
             guard: Guard.new([]),
             recorder: Reeve::Audit::Recorder,
             invocation_id: nil,
             invoked_at: nil,
             metadata: nil,
             &tool)
    Reeve.config.principal_resolver = ->(_context) { principal }
    body = tool || -> { [] }

    Reeve::Invocation.call(
      context(tool_name: tool_name, arguments: arguments, agent: agent,
              invocation_id: invocation_id, invoked_at: invoked_at, metadata: metadata),
      registry: FakeRegistry.new(guard.nil? ? {} : { tool_name => guard }),
      authorizer: FakeAuthorizer.new(decision || Reeve::Decision.allow(rule: "InvoicePolicy#index?")),
      scoper: FakeScoper.new(scope_result),
      recorder: recorder
    ) { body.call }
  end

  def context(**attributes)
    Reeve::Context.new(**attributes)
  end

  def entries
    Reeve::Audit::Entry.order(:id)
  end

  def only_entry
    raise "expected exactly one entry, got #{entries.count}" unless entries.one?

    entries.first
  end
end
