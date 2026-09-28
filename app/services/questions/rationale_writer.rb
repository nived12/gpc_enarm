# Writes, for a case generated before options carried one, why each distractor is not the
# answer — the explanation a student who chose it actually needs.
#
# The model is shown the whole question with the right answer marked, the statement it
# cites, and the rest of the guideline's statements: the most instructive distractors are
# right somewhere else in the same guideline, and it can only say where if it can read
# it. It writes nothing about the correct option, whose explanation already exists.
#
# With `rewrite: true` it writes again only the rationales Questions::RationaleVerifier
# rejected, showing the model the rejected text and the reason, so the second attempt
# knows what the first got wrong. A new rationale is unjudged until verified again.
module Questions
  class RationaleWriter < ApplicationService
    MAX_TOKENS = 3_000

    LETTERS = Verifier::LETTERS

    def initialize(clinical_case, run: nil, rewrite: false)
      super()
      @clinical_case = clinical_case
      @run = run
      @rewrite = rewrite
    end

    def call
      return failure("El caso no tiene preguntas con recomendación citada") if questions.empty?

      completion = Llm::Completion.call(role: :generator, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      record(completion.payload)
      written = Llm::Completion.json_in(completion.payload[:content])
      return failure("El modelo no devolvió JSON legible") if written.nil?

      success(written: apply(written))
    end

    def context_for_logging
      { clinical_case_id: clinical_case.id }
    end

    private

    attr_reader :clinical_case, :run, :rewrite

    def questions
      @questions ||= clinical_case.questions.includes(:answer_options, :recommendation).select do |question|
        question.recommendation && (!rewrite || question.answer_options.any?(&:rationale_rejected?))
      end
    end

    def prompt
      <<~TEXT
        Eres médico revisor de reactivos del ENARM. Cada pregunta ya tiene su respuesta
        correcta marcada con (correcta). Tu tarea es explicar los distractores.

        #{Prompt::RATIONALE_INSTRUCTIONS}
        #{rewrite_instructions}#{language}
        Caso clínico:
        #{clinical_case.stem}

        #{questions.map.with_index(1) { |question, index| block_for(question, index) }.join("\n")}
        Otras recomendaciones de la misma guía, por si algún distractor aplica en otro momento:
        #{GuidelineContext.new(questions)}

        Devuelve SOLO JSON, sin markdown, con una razón por cada distractor (nunca por la correcta):
        {"questions":[{"question":1,"rationales":{"B":"...","C":"...","D":"..."}}]}
      TEXT
    end

    def rewrite_instructions
      return "" unless rewrite

      "\nSolo reescribe las razones marcadas como RECHAZADA; un revisor explicó por qué. " \
        "Devuelve únicamente esas letras.\n"
    end

    def block_for(question, index)
      options = question.answer_options.each_with_index.map do |option, position|
        "  #{LETTERS[position]}) #{option.text}#{" (correcta)" if option.correct?}#{rejected(option)}"
      end

      <<~TEXT
        Pregunta #{index}: #{question.text}
        #{options.join("\n")}
        Por qué la correcta lo es: #{question.explanation}
        Recomendación citada: #{question.recommendation.readable_text.squish}
      TEXT
    end

    def rejected(option)
      return "" unless rewrite && option.rationale_rejected?

      "\n     RECHAZADA: #{option.rationale}\n     Motivo del revisor: #{option.rationale_note}"
    end

    def language
      return "" unless clinical_case.locale == "en"

      "\nEl caso está en inglés: escribe las razones EN INGLÉS.\n"
    end

    # Only distractors, only letters that exist, only text that says something — and in
    # a rewrite, only the rationales that were rejected. A reply about the correct option
    # or a letter the question does not have is dropped.
    def apply(written)
      Array(written["questions"]).sum do |entry|
        question = questions[entry["question"].to_i - 1]
        next 0 if question.nil? || !entry["rationales"].is_a?(Hash)

        entry["rationales"].sum do |letter, text|
          option = option_at(question, letter)
          next 0 unless writable?(option, text)

          option.update!(rationale: text.to_s.squish, rationale_verdict: nil, rationale_note: nil)
          1
        end
      end
    end

    def writable?(option, text)
      return false if option.nil? || option.correct? || text.to_s.squish.blank?

      !rewrite || option.rationale_rejected?
    end

    def option_at(question, letter)
      index = LETTERS.index(letter.to_s.strip.upcase)
      question.answer_options[index] if index
    end

    def record(usage)
      return if run.nil?

      run.charge!(usage)
      run.increment!(:attempts, 1)
    end
  end
end
