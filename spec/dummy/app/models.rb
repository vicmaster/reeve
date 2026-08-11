# frozen_string_literal: true

# Two principals with disjoint records — the host setup the compliance suite asks for —
# and one shared record set the tools query.
class User < ActiveRecord::Base; end
class Invoice < ActiveRecord::Base; end

# A plain policy object. Pundit works too; neither is a dependency.
class InvoicePolicy
  def self.authorize(principal, _action, record)
    return false if principal.nil?

    record.nil? || record.user_id == principal.id
  end

  def self.scope(principal, relation)
    relation.where(user_id: principal.id)
  end
end
