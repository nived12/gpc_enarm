# The second opinion on a best-available version, from another model family.
#
# Questions::Verifier answers from the recommendation alone, which here would point at
# the answer the version left out. So this one is told the ideal answer is not offered
# and asked, blind, which of the four is the best for this patient and whether one clearly
# stands out. The version is supported only when it lands on the option marked correct
# and says one does; a different choice disputes it, and anything else leaves it
# ambiguous. Only supported versions are dealt into a Modo ENARM sitting.
module Questions
  class BestAvailableVerifier < ApplicationService
    MAX_TOKENS = 800

    LETTERS = Verifier::LETTERS

    def initialize(version, run: nil)
      super()
      @version = version
      @run = run
    end

    def call
      completion = Llm::Completion.call(role: :verifier, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      record(completion.payload)
      judgement = Llm::Completion.json_in(completion.payload[:content])
      return failure("El verificador no devolvió JSON legible") unless judgement.is_a?(Hash)

      verdict = verdict_for(judgement)
      version.update!(best_available_verdict: verdict, best_available_note: judgement["note"].to_s.squish.presence)
      success(verdict: verdict)
    end

    def context_for_logging
      { question_id: version.id }
    end

    private

    attr_reader :version, :run

    def options
      @options ||= version.answer_options.to_a
    end

    def prompt
      <<~TEXT
        Eres médico revisor de reactivos del ENARM. En esta pregunta la respuesta ideal NO
        está entre las opciones, como ocurre a veces en el examen real. Con tu conocimiento
        médico, elige cuál de las cuatro es la mejor conducta para ESTE paciente entre las
        que se ofrecen, y di si una destaca con claridad sobre las demás ("clear": false si
        dos son igual de defendibles o ninguna lo es).

        Caso clínico:
        #{version.clinical_case.stem}

        Pregunta: #{version.text}
        #{options.each_with_index.map { |option, index| "#{LETTERS[index]}) #{option.text}" }.join("\n")}

        Devuelve SOLO JSON, sin markdown, con una nota de una oración:
        {"option":"B","clear":true,"note":"..."}
      TEXT
    end

    def verdict_for(judgement)
      index = LETTERS.index(judgement["option"].to_s.strip.upcase)
      chosen = options[index] if index
      return "ambiguous" if chosen.nil? || judgement["clear"] != true

      chosen.correct? ? "supported" : "disputed"
    end

    def record(usage)
      return if run.nil?

      run.charge!(usage)
      run.increment!(:attempts, 1)
    end
  end
end
