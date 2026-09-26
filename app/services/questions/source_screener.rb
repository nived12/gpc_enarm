# Decides, once per guideline, what of it an ENARM item may be written from.
#
# Reading the first 1,500 generated cases found the worst of them came from the source,
# not the writing: a rehabilitation or subspecialty guideline yields a question about a
# splint's angle or a surgical supply, and a statement about who fills in which form
# yields a question with nothing clinical in it. Rewording the prompt cannot fix a
# statement that has no general physician's decision in it, so the statement is never
# handed to the generator.
#
# Two judgements, both kept on the record so a rerun only asks what is still unknown:
#
# - the guideline's Guideline#enarm_relevance, from its title, its questions and a
#   sample of its statements. An out-of-scope guideline stops here.
# - each actionable statement's Recommendation#decision_kind, a slice at a time.
#
# A label the model leaves out or misspells is not stored, so the statement stays
# unscreened, is not generated from, and is asked again next time.
module Questions
  class SourceScreener < ApplicationService
    STATEMENTS_PER_CALL = 50
    SAMPLE_STATEMENTS = 12
    MAX_QUESTIONS = 20
    # A handful of statements are whole pages the PDF parser could not split. Their
    # opening says what they are about, and the rest would only be paid for.
    MAX_STATEMENT_CHARS = 700
    MAX_TOKENS = 2_000

    RELEVANCE_CODES = Guideline.enarm_relevances.keys.freeze
    DECISION_CODES = { "gp" => "general_practice", "specialist" => "specialist", "process" => "process" }.freeze

    def initialize(guideline, run: nil)
      super()
      @guideline = guideline
      @run = run
    end

    def call
      rate_relevance if guideline.enarm_relevance.nil?
      classify_statements unless has_errors? || guideline.relevance_out_of_scope?
      guideline.update_columns(screened_at: Time.current)
      return failure(payload: tally) if has_errors?

      success(tally)
    end

    def context_for_logging
      { guideline: guideline.catalog_key }
    end

    private

    attr_reader :guideline, :run

    def tally
      @tally ||= { relevance: nil, labelled: Hash.new(0) }
    end

    def rate_relevance
      reply = ask(relevance_prompt)
      return if reply.nil?

      relevance = reply["relevance"].to_s.strip.downcase
      unless RELEVANCE_CODES.include?(relevance)
        return add_error_message("La calificación de #{guideline.catalog_key} no es una de las previstas")
      end

      guideline.update!(enarm_relevance: relevance, relevance_note: reply["note"].to_s.squish.truncate(250).presence)
      tally[:relevance] = relevance
    end

    def classify_statements
      unscreened.each_slice(STATEMENTS_PER_CALL) do |slice|
        reply = ask(statements_prompt(slice))
        return if reply.nil?

        # Written a kind at a time, without validations: a legacy row that no longer
        # validates must not take the whole screen down with it.
        labelled = slice.each.with_index(1).group_by do |_, number|
          DECISION_CODES[reply[number.to_s].to_s.strip.downcase]
        end
        labelled.except(nil).each do |kind, statements|
          Recommendation.where(id: statements.map { |statement, _| statement.id }).update_all(decision_kind: kind)
          tally[:labelled][kind] += statements.size
        end
      end
    end

    def unscreened
      statements.where(decision_kind: nil).to_a
    end

    def statements
      guideline.recommendations.merge(GuidelineSection.actionable).reorder(:id)
    end

    # The reply as a Hash, or nil with the reason added to the errors.
    def ask(prompt)
      completion = Llm::Completion.call(role: :verifier, prompt: prompt, max_tokens: MAX_TOKENS)
      unless completion.success?
        add_error_message(completion.errors)
        return
      end

      run&.charge!(completion.payload)
      reply = Llm::Completion.json_in(completion.payload[:content])
      add_error_message("El modelo no devolvió JSON legible para #{guideline.catalog_key}") if reply.nil?
      reply
    end

    def relevance_prompt
      <<~TEXT
        Eres médico y preparas reactivos para el ENARM (Examen Nacional de Aspirantes a
        Residencias Médicas, México). El ENARM evalúa a un médico general: sospechar y
        diagnosticar, pedir e interpretar estudios básicos, dar el tratamiento inicial,
        prevenir y tamizar, reconocer una urgencia y saber cuándo referir, en consulta de
        medicina familiar, urgencias o salud pública. Califica qué tanto sirve esta Guía de
        Práctica Clínica para escribir casos del ENARM:

        - "core": trata padecimientos o situaciones que un médico general atiende o debe
          reconocer, y buena parte de sus recomendaciones sirven para una pregunta así.
        - "secondary": el padecimiento se pregunta en el ENARM, pero la guía está escrita
          sobre todo para especialistas; solo algunas recomendaciones sirven.
        - "out_of_scope": trata de manejo propio de un subespecialista, técnicas
          quirúrgicas o de procedimientos, rehabilitación, enfermería, organización de
          servicios o un tema que el ENARM no pregunta.

        Una guía de rehabilitación es "out_of_scope" aunque el padecimiento sí se
        pregunte: sus recomendaciones son terapias que prescribe el rehabilitador, y el
        diagnóstico y tratamiento inicial del padecimiento están en otras guías.

        Guía: #{guideline.title} (#{guideline.catalog_key}, #{guideline.year || "sin año"})
        Especialidades según el catálogo: #{guideline.specialty_labels.join(", ").presence || "sin dato"}

        Preguntas que responde la guía:
        #{clinical_questions.map { |question| "- #{question}" }.join("\n")}

        Algunas de sus recomendaciones:
        #{sample.map { |statement| "- #{excerpt(statement)}" }.join("\n")}

        Devuelve SOLO JSON, sin markdown. La nota dice en una oración por qué:
        {"relevance":"core","note":""}
      TEXT
    end

    def statements_prompt(slice)
      <<~TEXT
        Eres médico y preparas reactivos para el ENARM, que evalúa a un médico general.
        Estas recomendaciones son de la guía "#{guideline.title}". Clasifica cada una según
        lo que le pediría decidir a quien la sigue:

        - "gp": una decisión clínica que un médico general toma o debe conocer: sospechar o
          hacer un diagnóstico, pedir o interpretar un estudio, iniciar un tratamiento,
          prevenir, tamizar o vacunar, dar seguimiento, reconocer una urgencia, o saber
          cuándo y a dónde referir.
        - "specialist": lo decide, prescribe o ejecuta un especialista, aunque el médico
          general deba saber que existe: cirugía o procedimientos y su técnica, un insumo
          o dispositivo, quimioterapia, radioterapia y sus dosis, terapias de
          rehabilitación, fisioterapia u ortesis, un esquema de segunda línea en
          adelante, un parámetro que solo un especialista ajusta.
        - "process": no es una decisión clínica sobre un paciente: organización de
          servicios, registro o documentación, capacitación del personal, trámites,
          indicadores, recomendaciones de investigación, o un dato o resultado de un
          estudio sin nada que decidir.

        Ante la duda entre "gp" y otra, no es "gp": una pregunta del ENARM escrita desde
        esa recomendación tendría que poder responderla un médico general.

        #{slice.map.with_index(1) { |statement, number| "#{number}. #{excerpt(statement)}" }.join("\n")}

        Devuelve SOLO JSON, sin markdown, con una etiqueta por número y ninguno de más:
        {"1":"gp","2":"process"}
      TEXT
    end

    def clinical_questions
      guideline.guideline_sections.actionable.where.not(clinical_question: nil)
               .pluck(:clinical_question).map(&:squish).uniq.first(MAX_QUESTIONS)
    end

    # Spread across the guideline rather than its first statements, which are all
    # from its first question.
    def sample
      all = statements.to_a
      (0...SAMPLE_STATEMENTS).map { |index| all[index * all.size / SAMPLE_STATEMENTS] }.compact.uniq
    end

    def excerpt(statement)
      statement.text.squish.truncate(MAX_STATEMENT_CHARS)
    end
  end
end
