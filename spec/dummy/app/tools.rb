# frozen_string_literal: true

# The three shapes a tool can return, one each (plan.md T060).

# 1. A relation — merged with the policy scope before it is executed.
class InvoiceSearchTool
  include Reeve::Guard

  guard_with InvoicePolicy
  redact :customer_ssn

  def call(query: "", customer_ssn: nil)
    Invoice.where("number LIKE ?", "#{query}%")
  end
end

# 2. A single record — denied without a word if it is out of scope.
class InvoiceShowTool
  include Reeve::Guard

  guard_with InvoicePolicy

  def call(id:)
    Invoice.find_by(id: id)
  end
end

# 3. An aggregate — safe because it is computed from `scoped`, never from the model.
class OverdueTotalTool
  include Reeve::Guard

  guard_with InvoicePolicy

  def call
    scoped(Invoice).where(overdue: true).sum(:cents)
  end
end

# Deliberately undeclared, to show what a retrofit looks like before it is guarded.
class LegacyExportTool
  include Reeve::Guard

  def call
    Invoice.all
  end
end
