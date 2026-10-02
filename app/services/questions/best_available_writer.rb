# Writes a question's "best available answer" version for Modo ENARM.
#
# Students of the 2026 sitting met items whose ideal answer was not offered — no
# "eclampsia" for a pregnant patient who seized, no intubation after failed advanced
# airway management — and had to choose the best of what was there. The version keeps
# the case and the question, drops the correct option, marks the distractor closest to
# it as correct, adds one new distractor so there are still four, and explains both the
# ideal answer and why the chosen one is the best of those offered.
#
# Not every question allows it: when no remaining option is clearly better than the
# others, the item would have no defensible answer, so the model may decline and the
# question keeps no version. Reading the first 30 (2026-10-02) found the two shapes that
# fail: options that are figures ("beyond 38 weeks" for an ideal of 36 is no closer than
# 34) and a choice useful for a different reason (corticosteroids as a risk factor for
# osteosarcoma); the prompt now declines both. The code then checks what it can: the chosen option is one
# of the distractors, and the new one is not the ideal answer brought back.
module Questions
  class BestAvailableWriter < ApplicationService
    MAX_TOKENS = 2_000

    LETTERS = Verifier::LETTERS

    def initialize(question, run: nil)
      super()
      @question = question
      @run = run
    end

    def call
      return failure("La pregunta ya tiene su versión de mejor opción disponible") if question.best_available_variant
      unless options.size == Question::OPTION_COUNT && question.recommendation
        return failure("La pregunta no tiene cuatro opciones y una recomendación citada")
      end

      completion = Llm::Completion.call(role: :generator, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      record(completion.payload)
      @written = Llm::Completion.json_in(completion.payload[:content])
      return failure("El modelo no devolvió JSON legible") unless written.is_a?(Hash)
      return decline if written["suitable"] == false

      reason = refusal
      return failure(reason) if reason

      success(variant: create_variant)
    end

    def context_for_logging
      { question_id: question.id }
    end

    private

    attr_reader :question, :run, :written

    # Recorded on the original, so no later run pays to ask about this question again.
    def decline
      question.update!(best_available_declined_at: Time.current)
      success(variant: nil)
    end

    def options
      @options ||= question.answer_options.to_a
    end

    def prompt
      <<~TEXT
        Eres médico revisor de reactivos del ENARM. En el examen real, algunas preguntas no
        incluyen la respuesta ideal entre las opciones, y el sustentante debe elegir la mejor
        de las que hay. Vas a escribir esa versión de la pregunta de abajo.

        1. Se quita la opción correcta.
        2. De los tres distractores, elige el que sea claramente la mejor conducta para ESTE
           paciente entre los que quedan: el más cercano a la respuesta ideal. Debe ser
           defendible sin duda; si ninguno destaca con claridad sobre los otros dos, o si
           alguno sería peligroso como "mejor opción", responde {"suitable": false}.
           La elegida debe perseguir el MISMO objetivo clínico que la ideal, solo que peor
           (otro anticonvulsivo cuando falta el de elección, otro diurético, otro estudio
           para la misma sospecha). No vale una opción útil por otro motivo o para otro
           diagnóstico. Responde también {"suitable": false} si las opciones son cifras
           (semanas, edades, dosis, porcentajes, puntos de corte): entre números no hay una
           "más cercana" defendible.
        3. Escribe un distractor nuevo, del mismo tipo y longitud que los demás, plausible
           pero claramente inferior al elegido. No puede ser la respuesta ideal ni decir lo
           mismo con otras palabras.
        4. Escribe la explicación: cuál sería la respuesta ideal y por qué, que en esta
           pregunta no se ofrece, y por qué la elegida es la mejor de las que quedan. Tono
           didáctico, sin dirigirte al alumno.
        5. Para cada distractor que queda incorrecto (los otros dos y el nuevo), una razón
           breve de por qué es inferior a la elegida.
        #{language}
        Caso clínico:
        #{question.clinical_case.stem}

        Pregunta: #{question.text}
        #{options.each_with_index.map { |option, index| "#{LETTERS[index]}) #{option.text}#{" (correcta)" if option.correct?}" }.join("\n")}
        Por qué la correcta lo es: #{question.explanation}
        Recomendación citada: #{question.recommendation.readable_text.squish}

        Devuelve SOLO JSON, sin markdown:
        {"suitable":true,"best":"B","new_option":"...","explanation":"...",
        "rationales":{"C":"...","D":"...","new":"..."}}
      TEXT
    end

    def language
      return "" unless question.clinical_case.locale == "en"

      "\nEl caso está en inglés: escribe la opción nueva, la explicación y las razones EN INGLÉS.\n"
    end

    def best
      index = LETTERS.index(written["best"].to_s.strip.upcase)
      options[index] if index
    end

    def refusal
      return "El modelo eligió una opción que no es un distractor" if best.nil? || best.correct?
      return "Falta la opción nueva o la explicación" if new_option.blank? || written["explanation"].to_s.squish.blank?
      return "La opción nueva repite una de las que ya había" if repeats_an_option?
      return "Faltan razones para los distractores" if rationales.values_at(*wrong_keys).any?(&:blank?)

      nil
    end

    # Every option left wrong needs its own reason. The original's would explain why the
    # option loses to the ideal answer, which this version no longer offers.
    def rationales
      @rationales ||= (written["rationales"].is_a?(Hash) ? written["rationales"] : {})
                      .transform_values { |text| text.to_s.squish }
    end

    def wrong_keys
      options.reject do |option|
        option.correct? || option == best
      end.map { |option| LETTERS[options.index(option)] } + ["new"]
    end

    def new_option
      written["new_option"].to_s.squish
    end

    # The ideal answer brought back under its own words would make the item ordinary, and
    # a copy of a remaining distractor would leave two identical options.
    def repeats_an_option?
      options.any? { |option| Question.normalize(option.text) == Question.normalize(new_option) }
    end

    def create_variant
      Question.transaction do
        variant = question.create_best_available_variant!(
          clinical_case: question.clinical_case, position: question.position, text: question.text,
          explanation: written["explanation"].to_s.squish, recommendation: question.recommendation,
          source_quote: question.source_quote
        )
        kept = options.reject(&:correct?)
        kept.each.with_index(1) do |option, order|
          chosen = option == best
          variant.answer_options.create!(
            position: order, text: option.text, correct: chosen,
            rationale: (rationales[LETTERS[options.index(option)]] unless chosen)
          )
        end
        variant.answer_options.create!(
          position: Question::OPTION_COUNT, text: new_option, correct: false,
          rationale: rationales["new"]
        )
        variant
      end
    end

    def record(usage)
      return if run.nil?

      run.charge!(usage)
      run.increment!(:attempts, 1)
    end
  end
end
