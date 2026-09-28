# One batch of LLM work, with what it actually cost.
#
# Every clinical case points at the run that produced it, so a prompt or a model that
# turns out to write bad distractors can be retired wholesale instead of case by case.
# That matters because generation is the one thing in this app that costs real money and
# cannot be reproduced: the same prompt against the same model returns different wording.
class GenerationRun < ApplicationRecord
  include Exportable

  has_many :clinical_cases, dependent: :nullify

  enum :purpose,
    { generation: "generation", verification: "verification", bake_off: "bake_off", rationales: "rationales",
      screening: "screening", statement_repair: "statement_repair" },
    prefix: :purpose

  enum :status,
    { running: "running", completed: "completed", failed: "failed" },
    prefix: :status

  validates :provider, presence: true
  validates :model, presence: true

  scope :recent, -> { order(started_at: :desc) }

  # One completion's usage, charged the moment it is returned — before its reply is
  # parsed, since a reply that turns out to be unreadable was still paid for.
  def charge!(usage)
    increment!(:input_tokens, usage[:input_tokens].to_i)
    increment!(:output_tokens, usage[:output_tokens].to_i)
    increment!(:cost_usd, usage[:cost_usd].to_f)
    increment!(:calls, 1)
  end

  def tally_rejections!(reasons)
    merged = rejection_reasons.merge(reasons.transform_keys(&:to_s)) { |_reason, before, added| before + added }
    update!(rejection_reasons: merged)
  end

  def total_tokens
    input_tokens + output_tokens
  end

  # What it took to land one usable case. The bake-off ranks models on this next to
  # quality: a cheaper model that needs two passes is not a cheaper model.
  def attempts_per_case
    return if cases_created.zero?

    (attempts.to_f / cases_created).round(2)
  end
end
