# The second opinion on why each distractor is wrong.
#
# A rationale is model prose, not a quote, so the citation gate cannot see it — and the
# cheap generator overstates: it calls an arterial line during CPR "no es el estándar
# recomendado" when the guideline only says capnography is the better answer here, and
# a student would learn a rule nobody wrote.
#
# This is a call of its own rather than more lines in Questions::Verifier's prompt, on
# purpose. That prompt hides which option is marked correct, and a rationale on three
# options and none on the fourth names the answer; a verifier shown it agrees with the
# generator instead of answering blind, which is the failure the verifier exists to avoid.
#
# Only unjudged rationales are sent, so a rewritten rationale is judged again without
# reopening the ones already judged sound.
module Questions
  class RationaleVerifier < ApplicationService
    MAX_TOKENS = 3_000

    LETTERS = Verifier::LETTERS

    def initialize(clinical_case, run: nil)
      super()
      @clinical_case = clinical_case
      @run = run
    end

    def call
      return failure("El caso no tiene razones por verificar") if questions.empty?

      completion = Llm::Completion.call(role: :verifier, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      record(completion.payload)
      judgements = Llm::Completion.json_in(completion.payload[:content])
      return failure("El verificador no devolvió JSON legible") if judgements.nil?

      success(apply(judgements))
    end

    def context_for_logging
      { clinical_case_id: clinical_case.id }
    end

    private

    attr_reader :clinical_case, :run

    def questions
      @questions ||= clinical_case.questions.includes(:answer_options, :recommendation).select do |question|
        question.recommendation && question.answer_options.any? { |option| unjudged?(option) }
      end
    end

    def unjudged?(option)
      !option.correct? && option.rationale.present? && option.rationale_verdict.nil?
    end

    def prompt
      <<~TEXT
        Eres médico revisor de reactivos del ENARM. Cada pregunta tiene su respuesta
        correcta marcada con (correcta). Otro redactor escribió, para algunos distractores,
        por qué no son la mejor respuesta. Juzga cada una de esas razones usando el caso y
        las recomendaciones de la guía que se incluyen:

        - "sound": lo que afirma se sostiene en el caso y en las recomendaciones, o es
          conocimiento clínico básico que no las contradice.
        - "overstated": exagera. Dice que la opción "no se recomienda", "está
          contraindicada", "no es estándar", "es inaceptable" o algo igual de tajante,
          cuando las recomendaciones solo permiten decir que no es la mejor respuesta en
          este caso.
        - "contradicted": afirma algo que el caso o las recomendaciones contradicen, o
          inventa un dato, una cifra o una recomendación.

        Caso clínico:
        #{clinical_case.stem}

        #{questions.map.with_index(1) { |question, index| block_for(question, index) }.join("\n")}
        Otras recomendaciones de la misma guía:
        #{GuidelineContext.new(questions)}

        Devuelve SOLO JSON, sin markdown, un juicio por cada razón y ninguno por la correcta.
        La nota explica en una oración qué exagera o qué contradice; vacía si es "sound":
        {"rationales":[{"question":1,"option":"B","verdict":"sound","note":""}]}
      TEXT
    end

    def block_for(question, index)
      options = question.answer_options.each_with_index.map do |option, position|
        line = "  #{LETTERS[position]}) #{option.text}#{" (correcta)" if option.correct?}"
        unjudged?(option) ? "#{line}\n     Razón: #{option.rationale.squish}" : line
      end

      <<~TEXT
        Pregunta #{index}: #{question.text}
        #{options.join("\n")}
        Recomendación citada: #{question.recommendation.readable_text.squish}
      TEXT
    end

    # A judgement about an option that was not sent, or a verdict outside the three, is
    # dropped: the rationale stays unjudged and the next pass asks again.
    def apply(judgements)
      tally = AnswerOption.rationale_verdicts.keys.index_with(0)
      Array(judgements["rationales"]).each do |judgement|
        option = option_for(judgement)
        verdict = judgement["verdict"].to_s.strip.downcase
        next if option.nil? || tally.exclude?(verdict)

        option.update!(
          rationale_verdict: verdict,
          rationale_note: (judgement["note"].to_s.squish.presence unless verdict == "sound")
        )
        tally[verdict] += 1
      end
      tally.symbolize_keys
    end

    def option_for(judgement)
      question = questions[judgement["question"].to_i - 1] if judgement["question"].to_i.positive?
      return if question.nil?

      index = LETTERS.index(judgement["option"].to_s.strip.upcase)
      option = question.answer_options[index] if index
      option if option && unjudged?(option)
    end

    def record(usage)
      return if run.nil?

      run.charge!(usage)
      run.increment!(:attempts, 1)
    end
  end
end
