# One question asked about a clinical case, with the recommendation it came from.
#
# source_quote is the span of that recommendation the model claims to be using, and it
# must be a literal substring of it. That check runs in Ruby before the row is written —
# deterministic, free, and it catches a fabricated citation from any model, which is what
# makes generating on a cheap model acceptable at all.
class Question < ApplicationRecord
  belongs_to :clinical_case
  belongs_to :recommendation, optional: true

  has_many :answer_options, -> { order(:position) }, dependent: :destroy, inverse_of: :question
  has_many :question_reports, dependent: :destroy

  OPTION_COUNT = 4

  validates :text, presence: true
  validates :position, presence: true, uniqueness: { scope: :clinical_case_id }
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
