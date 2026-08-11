# frozen_string_literal: true

require_relative "authorization/declaration"
require_relative "authorization/registry"
require_relative "authorization/adapters/plain"
require_relative "authorization/adapters/pundit"
require_relative "authorization/adapter"
require_relative "authorization/current"
require_relative "authorization/authorizer"
require_relative "authorization/scoper"
require_relative "authorization/guard"

# Reeve — per-record authorization and an append-only audit ledger for MCP tools.
module Reeve
  # Per-record authorization: the registry of guard declarations, the policy adapters,
  # and the scoper that narrows a tool's return value to what the principal may see.
  module Authorization
  end

  class << self
    # The plain interface, and the composition root for every other one. An MCP server
    # adapter builds the Context and calls this; there is no second path into the
    # envelope, which is what makes "was this authorized and recorded?" answerable in
    # one place.
    #
    #   Reeve.invoke(tool: InvoiceSearchTool, arguments: { query: "AC" },
    #                principal: current_user, agent: { id: "claude-desktop" })
    def invoke(tool:, arguments: {}, principal: :unset, agent: nil, metadata: {}, &body)
      context = Context.new(
        tool_name: tool_name_for(tool),
        agent: agent,
        arguments: arguments,
        metadata: metadata
      )

      declaration = registry.guard_for(context.tool_name)
      adapter = declaration ? Authorization::Adapter.resolve(declaration.policy) : nil

      Authorization::Current.with(context: context, declaration: declaration, adapter: adapter) do
        Invocation.call(
          context,
          registry: registry,
          authorizer: Authorization::Authorizer.new,
          scoper: Authorization::Scoper.new,
          config: configuration_for(principal)
        ) { body ? body.call : run(tool, arguments) }
      end
    end

    private

    def run(tool, arguments)
      instance = tool.is_a?(Class) ? tool.new : tool
      arguments.empty? ? instance.call : instance.call(**arguments)
    end

    def tool_name_for(tool)
      klass = tool.is_a?(Class) ? tool : tool.class
      declaration = registry.for_class(klass)
      return declaration.tool_name if declaration
      return klass.tool_name.to_s if klass.respond_to?(:tool_name) && klass.tool_name

      Authorization::Declaration.new(tool_class: klass, policy: nil, action: :index).tool_name
    end

    # An explicitly supplied principal is just a resolver that returns it. Routing it
    # through the same resolution step rather than around it keeps one answer to "where
    # did this principal come from" — the envelope still resolves, records and denies
    # identically, and a nil passed in still denies with `no_principal`.
    def configuration_for(principal)
      return config if principal == :unset

      config.dup.tap { |scoped| scoped.principal_resolver = ->(_context) { principal } }
    end
  end
end
