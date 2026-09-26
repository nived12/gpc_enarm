# A single graded statement: the text, plus the evidence grade, the scale that grade
# belongs to, and the study it rests on.
#
# This is the unit a generated question cites. The anti-hallucination gate in Phase 2
# checks a question's source_quote against #text, so #text must stay exactly what the
# guideline published — never cleaned up, never paraphrased.
class Recommendation < ApplicationRecord
  belongs_to :guideline_section
  has_one :guideline, through: :guideline_section

  # What the statement asks of whoever follows it, read by Questions::SourceScreener. Only
  # a general physician's decision makes an ENARM item: a specialist's technique asks
  # what the exam does not, and a process statement — who fills in which form — asks
  # nothing clinical at all. Nil until screened, and gpc:reparse rebuilds uncited rows
  # without it, so a reparse is followed by another screen.
  enum :decision_kind,
    { general_practice: "general_practice", specialist: "specialist", process: "process" },
    prefix: :decision

  validates :text, presence: true
  validates :label, presence: true
  validates :position, presence: true, uniqueness: { scope: :guideline_section_id }

  scope :actionable, -> { joins(:guideline_section).merge(GuidelineSection.actionable) }
  scope :with_scale, ->(scale) { where(scale: scale) }

  def cited_as
    [grade, scale, citation].compact_blank.join(" · ").presence || label
  end

  # The guideline figure this statement sends the reader to ("ver cuadro 2"), if we hold
  # it. Shown with the answer's explanation, never with the question: a guideline's
  # algorithms, tables and scales are its reference material, and during the question
  # they would be the answer key.
  def figure
    ClinicalImage.cited_by([self])&.last
  end
end
