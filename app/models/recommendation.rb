# A single graded statement: the text, plus the evidence grade, the scale that grade
# belongs to, and the study it rests on.
#
# This is the unit a generated question cites. The anti-hallucination gate in Phase 2
# checks a question's source_quote against #text, so #text must stay exactly what the
# parser read — never cleaned up, never paraphrased.
#
# An archived PDF's citation column sometimes bleeds into that text ("hasta los 6 2007
# meses"). Gpc::StatementRepairer removes the stray fragments into #clean_text, deleting
# only, and #readable_text is what a student, and a model writing from it, reads. A quote
# taken from either passes the gate.
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
  # Not one the bleed cut letters out of ("ubicacióMorri"): deleting cannot mend it.
  scope :intact, -> { where(text_damaged: false) }
  scope :repair_pending, -> { where(repaired_at: nil) }

  # The SQL twin of #readable_text, for filters on what a reader will see.
  READABLE_TEXT_SQL = "COALESCE(recommendations.clean_text, recommendations.text)".freeze

  def readable_text
    clean_text.presence || text
  end

  def contains_quote?(quote)
    [text, clean_text].compact.any? { |candidate| Question.quote_in?(candidate, quote) }
  end

  # A quote taken from #text, with the same fragments removed, so it can be found (and
  # marked) inside #readable_text.
  def readable_quote(quote)
    return quote if quote.blank? || removed_fragments.empty?

    self.class.tidy(removed_fragments.reduce(quote) { |cut, fragment| self.class.without(cut, fragment) || cut }).squish
  end

  # The text with a fragment taken out, whatever whitespace the fragment spans (a model
  # reads the text with its line breaks collapsed). Nil unless the fragment stands in the
  # text exactly once clear of its neighbours: a year the statement really uses beside
  # one that bled in, or the "d" of "salud" for the grade "D", must not be the one cut.
  def self.without(text, fragment)
    pattern = Regexp.new(fragment.split.map { |word| Regexp.escape(word) }.join("\\s+"), Regexp::IGNORECASE)
    clear = text.to_enum(:scan, pattern).map { Regexp.last_match }.select { |match| clear?(match) }
    return unless clear.one?

    "#{clear.first.pre_match} #{clear.first.post_match}"
  end

  # Where the bleed is glued to the statement, the join still shows: a lowercase letter
  # running into a capital ("integralThe College"), or a letter into a digit
  # ("evitar2019"). A letter into a lowercase letter, or a digit into a digit ("20" out of
  # "200 mg"), is a cut through a word or a number.
  def self.clear?(match)
    first = match[0][0]
    last = match[0][-1]
    joins?(match.pre_match[-1], first, capital_allowed: true) && joins?(last, match.post_match[0])
  end

  def self.joins?(left, right, capital_allowed: false)
    return true unless left&.match?(/[\p{L}\d]/) && right&.match?(/[\p{L}\d]/)
    return false if left.match?(/\d/) && right.match?(/\d/)
    return true if left.match?(/\d/) || right.match?(/\d/)

    capital_allowed && left.match?(/\p{Ll}/) && right.match?(/\p{Lu}/)
  end

  # Deleting leaves doubled spaces and a space before punctuation; line breaks stay.
  def self.tidy(text)
    text.gsub(/[ \t]{2,}/, " ").gsub(/ +([,.;:)])/, '\\1').gsub(/\( +/, "(").gsub(/ +$/, "").strip
  end

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
