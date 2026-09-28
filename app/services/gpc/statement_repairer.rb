# Takes out of a statement the text that is not the statement.
#
# An archived guideline is a three-column table, and where the parser misjudged a row the
# grading column — citations, society names, years, "Punto de Buena Práctica" — bled into
# the statement: "hasta los 6 2007 meses" is "hasta los 6 meses" with half of "Pediatric
# Eye Evaluations 2007" inside it. The pearl built from it hid "2007 meses". About one
# statement in eight carries some of it.
#
# The model is shown a batch of statements and names, for each one that needs it, the
# fragments to delete, copied from the text. It never writes the statement: the code
# deletes what it named and nothing else, so the worst a wrong answer can do is remove a
# phrase. That is bounded too: a fragment must be found in the text, and a reply that
# would remove more than a third of a statement, or cut one where it runs into the next
# word, is refused and the statement left as it was. Where the bleed ate letters
# ("ubicacióMorri") deleting cannot mend the word, and the model says so: that statement
# is marked damaged and kept out of pearls and generation.
#
# Every statement in a batch the model answered is marked repaired, the ones it left
# alone too, so a rerun only reads what is still unread.
module Gpc
  class StatementRepairer < ApplicationService
    MAX_BATCH_CHARS = 8_000
    MAX_TOKENS = 3_000
    MAX_FRAGMENT_CHARS = 120
    MAX_REMOVED_SHARE = 1 / 3r

    def initialize(recommendations, run: nil)
      super()
      @recommendations = recommendations
      @run = run
    end

    def call
      reply = ask
      return failure(payload: tally) if reply.nil?

      recommendations.each.with_index(1) { |recommendation, number| settle(recommendation, reply[number.to_s]) }
      success(tally)
    end

    def context_for_logging
      { recommendations: recommendations.size }
    end

    # Consecutive statements, in batches a model reads in one go.
    def self.batches(recommendations)
      recommendations.each_with_object([[]]) do |recommendation, batches|
        chars = batches.last.sum { |queued| queued.text.squish.length } + recommendation.text.squish.length
        batches << [] if batches.last.any? && chars > MAX_BATCH_CHARS
        batches.last << recommendation
      end
    end

    private

    attr_reader :recommendations, :run

    def tally
      @tally ||= { read: 0, repaired: 0, damaged: 0, refused: 0 }
    end

    def settle(recommendation, answer)
      fragments = Array(answer.is_a?(Hash) ? answer["remove"] : nil).map do |fragment|
        fragment.to_s.squish
      end.compact_blank
      damaged = answer.is_a?(Hash) && answer["damaged"] == true
      clean = fragments.any? ? cut(recommendation.text, fragments) : nil
      refused = fragments.any? && clean.nil?

      recommendation.update_columns(
        clean_text: clean, removed_fragments: clean ? fragments : [],
        text_damaged: damaged && !refused, repaired_at: Time.current
      )
      count(clean, damaged && !refused, refused)
    end

    def count(clean, damaged, refused)
      tally[:read] += 1
      tally[:repaired] += 1 if clean
      tally[:damaged] += 1 if damaged
      tally[:refused] += 1 if refused
    end

    # The text without the fragments, or nil when one is not in it, is too long to be a
    # citation, or together they are too much of the statement to be only its margin.
    def cut(text, fragments)
      return if fragments.any? { |fragment| fragment.length > MAX_FRAGMENT_CHARS }
      return if fragments.sum(&:length) > text.squish.length * MAX_REMOVED_SHARE

      clean = text
      fragments.each do |fragment|
        return if ends_inside_a_word?(clean, fragment)

        clean = Recommendation.without(clean, fragment) or return
      end
      tidy(clean)
    end

    # "de(Consensus 50 Study ofrecer": a fragment named as ending in "of" takes the start
    # of the next word with it. Where a fragment's last letter runs straight into the
    # next word, where it ends cannot be told, so nothing is removed.
    def ends_inside_a_word?(text, fragment)
      match = text.match(Recommendation.fragment_pattern(fragment))
      match.present? && match[0].match?(/\p{L}\z/) && match.post_match.match?(/\A\p{L}/)
    end

    # Deleting leaves doubled spaces and a space before punctuation; line breaks stay.
    def tidy(text)
      text.gsub(/[ \t]{2,}/, " ").gsub(/ +([,.;:)])/, '\1').gsub(/\( +/, "(").gsub(/ +$/, "").strip
    end

    # The reply as a Hash, or nil with the reason added to the errors.
    def ask
      completion = Llm::Completion.call(role: :verifier, prompt: prompt, max_tokens: MAX_TOKENS)
      unless completion.success?
        add_error_message(completion.errors)
        return
      end

      run&.charge!(completion.payload)
      reply = Llm::Completion.json_in(completion.payload[:content])
      add_error_message("El modelo no devolvió JSON legible") if reply.nil?
      reply
    end

    def prompt
      <<~TEXT
        Estas recomendaciones se extrajeron de Guías de Práctica Clínica mexicanas en PDF.
        En el PDF cada recomendación está en una tabla, con una columna a la derecha que
        trae el nivel de evidencia y la cita: autores, sociedades o guías extranjeras
        (casi siempre en inglés), años, "Punto de Buena Práctica", "Shekelle", "SIGN",
        "NICE", "GRADE". Al leer el PDF, a veces pedazos de esa columna quedaron metidos
        a mitad de la recomendación, incluso pegados a una palabra. Ejemplos:

        - "hasta los 6 2007 meses" → quitar "2007" (era de "Pediatric Eye Evaluations 2007").
        - "manejo integralThe College of Optometrists y multidisciplinario" → quitar
          "The College of Optometrists".
        - "posterio2010la dosis" → no se arregla quitando: faltan letras. Es "damaged".
        - "vacunación,contra losriesgosque presente lainfección natural" → no se quita
          nada: son palabras de la recomendación a las que solo les faltan espacios.

        Para cada recomendación que tenga texto de la columna de citas metido, di qué
        pedazos hay que borrar, copiados letra por letra como aparecen. Un pedazo de la
        columna de citas no continúa la frase: es un nombre de autor, de sociedad o de
        guía, un año, un nivel de evidencia. Nunca borres nada que sea parte de la
        recomendación: una dosis, una edad, un año que la recomendación sí menciona, una
        escala o un nombre que la recomendación usa, ni palabras en español que siguen
        la idea de la frase aunque estén pegadas o mal escritas. Si dudas, no lo borres. Marca "damaged": true cuando al borrar quede una palabra
        mocha o incompleta porque el pedazo se comió letras.

        No incluyas las recomendaciones que están bien.

        #{recommendations.map.with_index(1) { |recommendation, number| "#{number}. #{recommendation.text.squish}" }.join("\n")}

        Devuelve SOLO JSON, sin markdown, con el número de cada recomendación que hay
        que corregir, o {} si ninguna:
        {"4":{"remove":["Pediatric Eye Evaluations","2007"],"damaged":false}}
      TEXT
    end
  end
end
