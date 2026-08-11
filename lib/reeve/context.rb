# frozen_string_literal: true

require "English"
require "securerandom"

module Reeve
  # The per-invocation carrier: who is calling, on whose behalf, which tool, with what.
  #
  # Created by an adapter or by the caller of the plain interface — never global, never
  # reused between invocations. The principal is the only mutable field, because the
  # envelope resolves it after the context exists, and clears it in an +ensure+.
  class Context
    UNKNOWN_AGENT_ID = "unknown"

    attr_reader :invocation_id, :tool_name, :arguments, :metadata, :agent, :invoked_at
    attr_accessor :principal

    def initialize(tool_name:, principal: nil, agent: nil, arguments: nil, metadata: nil,
                   invoked_at: nil, invocation_id: nil)
      @tool_name     = validate_tool_name(tool_name)
      @principal     = principal
      @agent         = build_agent(agent)
      @arguments     = symbolize(:arguments, arguments)
      @metadata      = symbolize(:metadata, metadata)
      @invoked_at    = invoked_at || Time.now
      @invocation_id = (invocation_id || SecureRandom.uuid).to_s
    end

    def principal_resolved?
      !principal.nil?
    end

    # Called from the envelope's ensure block: nothing about one invocation may survive
    # into the next on the same thread (data-model invariant 4).
    def clear_principal!
      @principal = nil
    end

    def principal_type
      principal&.class&.name
    end

    def principal_id
      return nil if principal.nil?

      principal.respond_to?(:id) ? principal.id.to_s : principal.to_s
    end

    def agent_id
      agent[:id]
    end

    def agent_name
      agent[:name]
    end

    # The audit-facing projection. The recorder adds the outcome, rule and records;
    # everything here is known before the tool runs.
    def to_h
      {
        invocation_id: invocation_id,
        occurred_at: invoked_at,
        tool_name: tool_name,
        agent_id: agent_id,
        agent_name: agent_name,
        principal_type: principal_type,
        principal_id: principal_id,
        arguments: arguments
      }
    end

    def inspect
      "#<Reeve::Context tool=#{tool_name.inspect} principal=#{principal_id.inspect} " \
        "agent=#{agent_id.inspect} invocation=#{invocation_id.inspect}>"
    end

    private

    def validate_tool_name(name)
      string = name&.to_s
      return string if string && !string.strip.empty?

      raise ArgumentError, "tool_name is required and may not be blank (got #{name.inspect})"
    end

    def build_agent(agent)
      attributes = symbolize(:agent, agent)
      id = attributes[:id]
      attributes[:id] = id.nil? || id.to_s.strip.empty? ? UNKNOWN_AGENT_ID : id.to_s
      attributes[:name] = attributes[:name].to_s unless attributes[:name].nil?
      attributes
    end

    def symbolize(field, hash)
      return {} if hash.nil?

      raise ArgumentError, "#{field} must be a Hash, got #{hash.class}" unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        result[key.respond_to?(:to_sym) ? key.to_sym : key] = value
      end
    end
  end
end
