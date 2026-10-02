# Turns the JSON a model returned into saved clinical cases, keeping only what passes.
#
# Nothing the model says is trusted. Every question must name the recommendation it used
# and quote a span of it, and that quote is checked against the stored text before the row
# is written. A question that fails is dropped and counted, never repaired — a citation we
# had to fix is a citation the model did not actually have.
module Questions
  class CaseBuilder < ApplicationService
    # Seeded from the strength of the evidence behind the case: a strong recommendation
    # makes a more clear-cut item than a weak one. Recalibrated from real answer data
    # later, which is what CIFRHS itself does.
    STRONG_GRADES = /\A(A|1\+{1,2}|I{1,2}[ab]?|alta|fuerte)\b/i
    WEAK_GRADES = /\A(D|4|IV|muy baja|baja|d[ée]bil)\b/i

    # The vignette is the patient; the question lives only on Question. A stem that ends
    # by asking something shows the student a question nobody answers, above the one
    # they are asked (the pilot's case 250 did, and four more with it).
    ENDS_IN_A_QUESTION = /[?？]["'”»)\]]*\z/

    # A question's own text found inside the stem is the same defect without the mark.
    # Below this length a "question" is a word or two, which any vignette may contain.
    QUESTION_ECHO_MIN_LENGTH = 20

    # The prompt asks for 130 words at the least; this is the floor under it. The first
    # pilot's short cases (52–90 words) were the thin ones, with the obvious distractors.
    MIN_STEM_WORDS = 80

    # The convocatoria examines two or three questions per case. A case the rejections
    # left with one is not the format the student will sit.
    MIN_QUESTIONS = 2

    # `recommendations` must be in the order the prompt numbered them, since that number
    # is how the model says which one it used.
    def initialize(payload, guideline:, recommendations:, run: nil, locale: "es")
      super()
      @payload = payload
      @guideline = guideline
      @recommendations = recommendations
      @run = run
      @locale = locale
      @rejected = 0
      @reasons = Hash.new(0)
    end

    def call
      cases = Array(payload["cases"]).filter_map { |attributes| build_case(attributes) }

      success(cases: cases, rejected: rejected, reasons: reasons)
    end

    def self.asks_question?(stem, question_texts)
      return true if stem.to_s.strip.match?(ENDS_IN_A_QUESTION)

      vignette = echo_form(stem)
      question_texts.any? do |text|
        echo = echo_form(text)
        echo.length >= QUESTION_ECHO_MIN_LENGTH && vignette.include?(echo)
      end
    end

    def self.echo_form(text)
      text.to_s.downcase.delete("¿?¡!").squish
    end

    private

    attr_reader :payload, :guideline, :recommendations, :run, :locale, :rejected, :reasons

    def build_case(attributes)
      questions = Array(attributes["questions"])
      return if attributes["stem"].blank? || questions.empty?
      return reject(questions.size, :stem_asks_question) if stem_asks_question?(attributes["stem"], questions)
      return reject(questions.size, :stem_too_short) if attributes["stem"].split.size < MIN_STEM_WORDS

      kase = ClinicalCase.new(
        stem: attributes["stem"], guideline: guideline, generation_run: run,
        topic: topic, specialty: topic&.branch&.specialty, setting: setting(attributes["setting"]),
        source: "gpc_generated", locale: locale
      )
      built = questions.filter_map.with_index(1) { |question, position| build_question(kase, question, position) }
      built = one_per_statement(kase, built)
      return if built.empty?
      return reject(built.size, :too_few_questions) if built.size < MIN_QUESTIONS

      # A rejected question must not leave a hole. Positions number what survived, not
      # what the model sent, or a case reads "Pregunta 1, Pregunta 3" to a student.
      built.each.with_index(1) { |question, position| question.position = position }

      kase.difficulty = difficulty_for(built)
      kase.save!
      kase
    end

    def build_question(kase, attributes, position)
      options = Array(attributes["options"])
      question = kase.questions.build(
        position: position, text: attributes["text"], explanation: attributes["explanation"],
        recommendation: cited(attributes["recommendation"]), source_quote: attributes["quote"]
      )
      options.each.with_index(1) do |option, order|
        correct = option["correct"] ? true : false
        question.answer_options.build(
          position: order, text: option["text"], correct: correct,
          rationale: (option["rationale"].to_s.squish.presence unless correct)
        )
      end

      reason = rejection_for(question, options)
      return question if reason.nil?

      kase.questions.delete(question)
      reject(1, reason)
    end

    # One statement carries one question. Reading 60 cases on 2026-09-26, the weakest
    # questions were the second and third drawn from a statement the first had used up:
    # to ask something new they invented a detail the statement lacks, or asked an
    # administrative one (sick-leave days during chemotherapy). The first to cite a
    # statement keeps it.
    def one_per_statement(kase, built)
      built.uniq(&:recommendation).tap do |kept|
        (built - kept).each do |repeat|
          kase.questions.delete(repeat)
          reject(1, :repeats_statement)
        end
      end
    end

    def reject(count, reason)
      @rejected += count
      @reasons[reason.to_s] += count
      nil
    end

    def stem_asks_question?(stem, questions)
      self.class.asks_question?(stem, questions.map { |question| question["text"] })
    end

    # The model numbers the statements itself, so a number outside the list means it
    # invented the reference. Nil, and rejection_for drops the question.
    def cited(number)
      index = number.to_i - 1
      recommendations[index] unless index.negative?
    end

    # Four options, exactly one of them correct, and a quote that really is in the cited
    # recommendation. The quote check lives on Question so that nothing can write a
    # question that skips it; this only decides whether to keep the row at all, and names
    # why not, so a run can say which defect cost it money.
    def rejection_for(question, options)
      return :unknown_recommendation if question.recommendation.nil?
      return :wrong_option_count unless options.size == Question::OPTION_COUNT
      return :not_one_correct unless options.count { |option| option["correct"] } == 1
      return if question.valid?

      question.errors.of_kind?(:source_quote, :not_in_recommendation) ? :quote_not_in_recommendation : :incomplete
    end

    # Only called with questions that passed rejection_for, so every one has a recommendation;
    # a missing grade is the only gap, and filter_map drops it.
    def difficulty_for(questions)
      grades = questions.filter_map { |question| question.recommendation.grade }
      return "low" if grades.any? { |grade| grade.match?(STRONG_GRADES) }
      return "high" if grades.any? { |grade| grade.match?(WEAK_GRADES) }

      "medium"
    end

    # The context the model says it set the case in. A code it made up, or none at all,
    # leaves the setting unknown — questions:classify_settings can read the stem later —
    # and never costs the case: where it happens is filing, not content.
    def setting(code)
      settings.fetch(code.to_s) { settings[code.to_s] = Specialty.for_setting_code(code) }
    end

    def settings
      @settings ||= {}
    end

    def topic
      return @topic if defined?(@topic)

      @topic = guideline.main_topic
    end
  end
end
