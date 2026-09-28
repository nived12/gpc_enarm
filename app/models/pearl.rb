# A guideline statement studied as a flashcard: the statement with one phrase hidden,
# then the whole of it, its grade and its guideline's year.
#
# A Recommendation already is a pearl — graded, cited, dated — so nothing is generated
# and nothing is paraphrased. The hidden phrase is found by two fixed rules and is always
# a literal span of the statement as the guideline published it:
#
# 1. the first quantity with a unit — a dose, a duration, a threshold, an age ("0.9 mg/kg",
#    "4.5 horas", "≥ 60 años"), which is what the exam asks about statements like these.
#    Not one inside parentheses (usually a maximum or an aside) and not a statistic
#    ("IC 95%", "sensibilidad de 88%"), which is the study's number, not the advice;
# 2. otherwise, the action the statement recommends: the words after "se recomienda",
#    "se sugiere", "debe"… up to the first clause break, at most eight of them. Skipped
#    when that phrase is only grammar ("que el personal…", "ser evitado").
#
# A statement neither rule fits is not a pearl. Measured on 2026-09-23 over the 2,104
# statements that pass the pool's filters, rule 1 fits 468 and rule 2 roughly 1,000 more.
class Pearl
  LENGTH = (50..320)

  # A statement that points at a figure reads as half a sentence without it, and a figure
  # never goes with a prompt: it is the answer key.
  FIGURE_WORDS = "(cuadro|tabla|algoritmo|diagrama|figura|escala|anexo)"

  UNIT = /(?:mg|mcg|µg|g|gr|kg|ml|l|UI|U|mEq|mmol|mmHg|cm|mm|lpm|%|d[ií]as?|semanas?|mes(?:es)?|años?|
            horas?|hrs?|h|minutos?|min|segundos?|dosis|veces)/ix
  NUMBER = /\d+(?:[.,]\d+)?/
  PER = %r{\s*/\s*(?:kg|m2|d[ií]a|h|hora|dosis|min)}i
  QUANTITY = /(?<![\w.,])(?:[<>≤≥]\s*)?#{NUMBER}(?:\s*(?:a|-|–|y|o)\s*#{NUMBER})?\s*#{UNIT}(?:#{PER})*(?!\w)/i
  STATISTIC = /\b(?:IC|RR|OR|HR|sensibilidad|especificidad)\b/i

  VERB = /\b(?:se\s+recomienda|se\s+sugiere|recomendamos|sugerimos|se\s+debe|se\s+deber[áa]n?|deben?|deber[áa]n?)\s+/i
  CLAUSE_BREAK = /[,.;:()]|\s(?:en|para|con|cuando|si|durante|ya|debido|a\s+fin|por|que|sin|mientras|hasta|desde)\s/i
  ACTION = /\A\S+(?:\s+\S+){1,7}/
  GRAMMAR_ONLY = %w[que de ser a].freeze
  # A phrase cut at eight words can end on a conjunction or an article ("higiene dental
  # y"); the hidden span stops before it.
  DANGLING = /(?:\s+(?:y|o|e|u|de|del|el|la|los|las|a|al|un|una))+\z/i

  attr_reader :recommendation, :range

  # New statements a student may add to their deck in one study day; cards due for review
  # are never capped. Every new card comes back after 1 and 6 days and then at growing
  # intervals, so each day's new cards become the reviews of the weeks after, and an
  # unlimited intake buries what is due under statements met once. Twenty is Anki's
  # default for new cards a day, and two sessions of ten.
  NEW_PER_DAY = 20

  def self.new_allowance_spent?(user)
    ReviewCard.where(user: user).pearls.where(created_at: user.study_day_times).count >= NEW_PER_DAY
  end

  # The statements a pearls session draws from: actionable, graded, from a dated
  # guideline that has published cases, short enough to read in one breath, not
  # leaning on a figure, and not one the PDF's citation column cut letters out of.
  def self.pool
    Recommendation.actionable.joins(guideline_section: :guideline)
                  .where(guideline_sections: { guideline_id: ClinicalCase.status_published.select(:guideline_id) })
                  .where.not(grade: [nil, ""]).where.not(guidelines: { year: nil })
                  .intact
                  .where("char_length(#{Recommendation::READABLE_TEXT_SQL}) BETWEEN ? AND ?", LENGTH.min, LENGTH.max)
                  .where.not("#{Recommendation::READABLE_TEXT_SQL} ~* ?", FIGURE_WORDS)
  end

  # Nil when neither rule finds a phrase to hide, and for a statement marked damaged
  # after a student already held its card.
  def self.for(recommendation)
    return if recommendation.text_damaged?

    text = recommendation.readable_text
    range = quantity_range(text) || action_range(text)
    new(recommendation, range) if range
  end

  def self.quantity_range(text)
    text.to_enum(:scan, QUANTITY).map { Regexp.last_match }
        .find { |match| !aside?(text, match.begin(0)) }
        &.then { |match| match.begin(0)...match.end(0) }
  end

  def self.action_range(text)
    verb = text.match(VERB) or return
    rest = verb.post_match
    phrase = rest[0...(rest.index(CLAUSE_BREAK) || rest.length)].match(ACTION) or return
    words = phrase[0].sub(DANGLING, "")
    return if words.split.size < 2 || GRAMMAR_ONLY.include?(words.split.first.downcase)

    start = verb.end(0)
    start...(start + words.length)
  end

  def self.aside?(text, position)
    before = text[0...position]
    before.count("(") > before.count(")") || before.last(25).match?(STATISTIC)
  end

  def initialize(recommendation, range)
    @recommendation = recommendation
    @range = range
  end

  def before = text[0...range.begin]
  def answer = text[range]
  def after = text[range.end..]
  def guideline = recommendation.guideline

  private

  def text = recommendation.readable_text
end
