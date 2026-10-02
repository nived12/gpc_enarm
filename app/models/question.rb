# One question asked about a clinical case, with the recommendation it came from.
#
# source_quote is the span of that recommendation the model claims to be using, and it
# must be a literal substring of it. That check runs in Ruby before the row is written —
# deterministic, free, and it catches a fabricated citation from any model, which is what
# makes generating on a cheap model acceptable at all.
class Question < ApplicationRecord
  belongs_to :clinical_case
  belongs_to :recommendation, optional: true

  # Modo ENARM's "best available answer" version of this question: the ideal answer left
  # out, the closest remaining option marked correct, and an explanation that names the
  # ideal one. Students in the 2026 sitting met items like that; practice never shows
  # them, so the real answer is still what a student learns. Questions::BestAvailableWriter
  # writes them and Exams::Builder deals some into a Modo ENARM sitting.
  belongs_to :variant_of, class_name: "Question", optional: true, inverse_of: :best_available_variant
  has_one :best_available_variant, class_name: "Question", foreign_key: :variant_of_id,
    dependent: :destroy, inverse_of: :variant_of

  has_many :answer_options, -> { order(:position) }, dependent: :destroy, inverse_of: :question
  has_many :question_reports, dependent: :destroy

  OPTION_COUNT = 4

  validates :text, presence: true
  validates :position, presence: true
  validates :position, uniqueness: { scope: :clinical_case_id, conditions: -> { originals } }, unless: :variant_of_id?

  # Everything a case asks outside Modo ENARM. Every query that counts or draws a case's
  # questions reads these, never Question alone.
  scope :originals, -> { where(variant_of_id: nil) }
  validate :quote_must_come_from_the_recommendation

  # Whether a recommendation's text contains a quote, by the gate's own rule below.
  def self.quote_in?(text, quote)
    normalize(text).include?(normalize(quote))
  end

  def self.normalize(text)
    text.to_s.squish.downcase
  end

  def correct_option
    answer_options.find(&:correct?)
  end

  # What the review screen shows: the recommendation, its grade, and the year, so a
  # student can judge an eight-year-old guideline for herself.
  def citation
    recommendation&.cited_as
  end

  private

  # Compared with whitespace collapsed and case ignored on both sides. Two differences
  # show up constantly and neither is a fabrication:
  #
  #   * extraction keeps the line breaks the source had — "se deben evitar:\nPicos
  #     hiperóxicos" — and a model quoting that writes a space;
  #   * a model lowercases the first letter to fit the quote into its own sentence,
  #     turning "Se recomienda" into "se recomienda".
  #
  # Measured across two unrelated model families, those two accounted for every
  # citation rejection in the first provider comparison — the gate was refusing correct
  # quotes. Neither normalisation changes a word, so a paraphrase still cannot pass.
  def quote_must_come_from_the_recommendation
    return if source_quote.blank? || recommendation.nil?
    return if recommendation.contains_quote?(source_quote)

    errors.add(:source_quote, :not_in_recommendation)
  end
end
