# One of exactly four options on a question.
#
# A table rather than a jsonb array on purpose: *which* wrong answer a student picks is
# the most useful weak-spot signal in the product, and that only stays queryable if each
# distractor is a row.
class AnswerOption < ApplicationRecord
  belongs_to :question

  # What the second model family made of the rationale. `overstated` is the cheap
  # generator's habit of calling a distractor "inaceptable" or "no recomendado" when the
  # guideline only says it is not the answer here; `contradicted` is a rationale the case
  # or the guideline says is wrong. Both are kept for a doctor to read and never shown to
  # a student.
  enum :rationale_verdict,
    { sound: "sound", overstated: "overstated", contradicted: "contradicted" },
    prefix: :rationale

  REJECTED_RATIONALE = %w[overstated contradicted].freeze

  validates :text, presence: true
  validates :position, presence: true, uniqueness: { scope: :question_id }

  scope :correct, -> { where(correct: true) }
  # The rationale pipeline reads a case's questions, which are its originals; a
  # best-available version's options are judged with the version instead.
  scope :of_originals, -> { joins(:question).merge(Question.originals) }
  scope :with_rationale, -> { where(correct: false).where.not(rationale: nil) }
  scope :rationale_unjudged, -> { with_rationale.where(rationale_verdict: nil) }
  scope :rationale_rejected, -> { with_rationale.where(rationale_verdict: REJECTED_RATIONALE) }

  # Unjudged rationales stay visible: the whole pilot bank predates the check, and
  # hiding them all would take away the explanation the students asked for.
  def rationale_visible?
    !correct? && rationale.present? && REJECTED_RATIONALE.exclude?(rationale_verdict)
  end

  def rationale_rejected?
    REJECTED_RATIONALE.include?(rationale_verdict)
  end
end
