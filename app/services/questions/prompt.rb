# The words a generation call sends the model.
#
# Kept apart from the call itself because this is the part a doctor reviews and the part
# most likely to change after a batch is read: it should read top to bottom as the text it
# produces, with nothing about HTTP, JSON or rows in between.
module Questions
  class Prompt
    CASES = 2

    # A real ENARM vignette carries a whole patient — comorbidities with durations,
    # complete vitals with units, a systematic examination — and then asks about one
    # part of it. Ours were about 45 words with every fact pointing at the answer, which
    # a doctor reading them spotted immediately as too easy. `full_workup` is that whole
    # patient; `focused` stays short, because not every real item is long either.
    #
    # Questions per case: the convocatoria says two to three, and a longer vignette earns
    # the third, since there is more in it to ask about.
    QUESTIONS_BY_DETAIL = { focused: 2, full_workup: 3 }.freeze
    DETAIL_LEVELS = QUESTIONS_BY_DETAIL.keys.freeze

    # Two full workups for every focused case. Alternating one to one (until 2026-09-25)
    # made half the bank 52–90 words long, and reading the validation batch found the
    # short half was where the thin cases and the obvious distractors were.
    def self.detail_for(index)
      (index % 3) == 2 ? :focused : :full_workup
    end

    # The convocatoria (§9.1) examines "competencias cognitivas contextualizadas en casos
    # clínicos enfocados en Salud Pública, Urgencias y Medicina Familiar" — the three
    # contexts are where a case happens, the four troncales are what it is about. The
    # model picks the setting that fits the recommendation; a fixed rotation would put a
    # neonatal resuscitation in a family-medicine consult.
    #
    # It also names the one it chose, as a fixed code (Specialty::SETTING_SLUGS), so the
    # case is filed under that context as well as under its subject without anyone
    # reading the vignette to find out. Questions::CaseBuilder stores it.
    SETTING_INSTRUCTIONS = <<~TEXT.strip
      Sitúa cada caso en uno de los tres contextos del examen: la consulta de medicina
      familiar en el primer nivel, un servicio de urgencias, o una situación de salud
      pública (tamizaje, vacunación, brote, vigilancia epidemiológica, prevención en la
      comunidad). Elige el que encaje con la recomendación, y si escribes dos casos, que no
      ocurran en el mismo contexto cuando el tema lo permita. No sitúes el caso en una sala
      de hospitalización genérica. En el campo "setting" de cada caso escribe el contexto
      que elegiste, con uno de estos códigos exactos: #{Specialty::SETTING_SLUGS.keys.join(", ")}.
    TEXT

    # Asked for after a student chose a distractor and could not tell why it was wrong: the
    # explanation said why the answer was right, which is a different fact. Many of the
    # best distractors are right somewhere else in the same guideline — the ECG it
    # recommends after the circulation returns, not during compressions — and saying so is
    # the lesson. Shared with Questions::RationaleWriter, which writes them for cases
    # generated before this existed.
    RATIONALE_INSTRUCTIONS = <<~TEXT.strip
      - Para cada distractor, una razón breve (una o dos oraciones) de por qué no es la
        mejor respuesta en ESTE caso: qué es o para qué sirve esa opción, y qué le falta
        frente a lo que se pregunta. Si la opción es correcta en otro momento o situación
        que las recomendaciones describen, dilo. Si la opción es útil pero no responde lo
        que se pregunta, di eso; no afirmes que algo "no se recomienda" o "no es estándar"
        salvo que las recomendaciones lo digan. Tono respetuoso y didáctico: explica, no
        reprendas, sin calificativos tajantes como "inaceptable", y no te dirijas al alumno.
        Apóyate solo en el caso y en las recomendaciones; no inventes cifras, datos ni
        recomendaciones.
    TEXT

    # Five of the pilot's 197 vignettes, case 250 among them, ended with a question of
    # their own; the student then read a question nobody answers above the one they are
    # asked. Questions::CaseBuilder rejects any that still do.
    STEM_INSTRUCTIONS = <<~TEXT.strip
      La viñeta ("stem") solo describe al paciente y termina con un dato clínico, nunca con
      una pregunta: no escribas en ella "¿Cuál es…?", "What is…?" ni ninguna otra pregunta
      o instrucción al alumno. Cada pregunta va únicamente en su propio campo "text".
    TEXT

    # From reading the validation batch (2026-09-25): a question whose answer is a finding the
    # vignette already names ("¿qué signo es característico?" over a stem listing it), a
    # second question about a hypothetical other patient, two questions asking the same
    # thing, and distractors nobody would choose. Each makes the item easier than the real
    # exam, and the point is passing the real exam.
    #
    # The first 500-call chunk (2026-09-25) added three more, all invisible to a verifier
    # that only asks whether the recommendation backs the option: an answer right for a
    # different patient (repeat the ultrasound in weeks, for a vasa previa that is
    # bleeding), specialist detail (the irrigation solution for corneal surgery), and
    # administrative trivia (who instils the surfactant). The exam tests a general
    # physician's decisions.
    QUESTION_INSTRUCTIONS = <<~TEXT.strip
      Cada pregunta:
      - La opción correcta es la mejor conducta para ESTE paciente tal como lo describe la
        viñeta. Si la recomendación aplica a otra situación (paciente asintomático, sin
        sangrado, estable, en otro momento), escribe la viñeta para que sí aplique; nunca
        marques como correcta una conducta que sería un error en el paciente descrito.
      - Pregunta lo que un médico general debe saber y decidir: diagnóstico, estudio
        inicial, tratamiento de primera línea, urgencias, referencia oportuna, prevención y
        seguimiento. No preguntes detalles de subespecialidad (técnicas o insumos
        quirúrgicos, pruebas o índices que solo usa el especialista) ni datos
        administrativos (quién realiza un procedimiento, cómo se entrega la información).
        Si una recomendación solo trata esos detalles, no la uses.
      - Evalúa una decisión clínica que el alumno debe razonar integrando los datos del caso
        con la recomendación, con la dificultad del ENARM real. Nunca pregunta por un dato
        que la viñeta ya dice: si la viñeta describe un signo, no preguntes cuál es el signo.
      - Trata sobre ESTE paciente. No introduzcas otro paciente hipotético ni cambies de
        caso a mitad de la pregunta.
      - Las preguntas de un mismo caso evalúan decisiones distintas (diagnóstico, estudio,
        tratamiento, seguimiento o prevención); no repitas la misma pregunta con otras
        palabras.
      - El enunciado no contiene palabras que delaten la opción correcta.
      - Exactamente CUATRO opciones: una correcta y tres distractores. Las cuatro son del
        mismo tipo (todas fármacos, todas estudios, todas conductas) y de longitud y forma
        parecidas; la correcta no es la más larga ni la más detallada.
      - Cada distractor es algo que un médico consideraría para este paciente: lo correcto
        en otro momento o situación, una alternativa de segunda línea, o un error frecuente
        de quien estudió el tema de forma incompleta. Nunca una opción absurda, peligrosa o
        que nadie elegiría: un distractor evidente hace inútil el reactivo. Ningún
        distractor puede ser también correcto según las recomendaciones. Sin opciones como
        "todas las anteriores" o "ninguna de las anteriores": el orden de las opciones cambia
        en cada examen.
    TEXT

    # An unknown detail level falls back to focused rather than failing the call.
    def initialize(guideline, recommendations, detail: :focused, locale: "es")
      @guideline = guideline
      @recommendations = recommendations
      @detail = DETAIL_LEVELS.include?(detail) ? detail : :focused
      @locale = locale
    end

    def to_s
      <<~TEXT
        Eres redactor de reactivos para el ENARM, el examen nacional de residencias médicas
        en México. Escribes con terminología clínica formal.

        A partir de las siguientes recomendaciones de la guía de práctica clínica
        "#{guideline.title}", escribe #{CASES} casos clínicos, cada uno con
        #{questions_per_case} preguntas de opción múltiple.

        #{vignette_instructions}

        #{STEM_INSTRUCTIONS}

        #{SETTING_INSTRUCTIONS}

        #{QUESTION_INSTRUCTIONS}

        Además, en cada pregunta:
        - Una explicación breve de por qué la correcta lo es.
        #{RATIONALE_INSTRUCTIONS}
        - El número de la recomendación en la que se basa, y una cita textual de esa
          recomendación.
        - Ni la pregunta ni las opciones mencionan cuadros, algoritmos, figuras ni escalas de
          la guía: el alumno no los ve mientras responde, y una opción que dice "según el
          algoritmo 1" delata la respuesta.

        Sobre la cita: copia un fragmento CONTINUO, palabra por palabra, tal como aparece.
        NUNCA uses puntos suspensivos ni omitas palabras intermedias. Si el fragmento útil
        es largo, cita una parte contigua más corta.
        #{language_instructions}
        Devuelve SOLO JSON, sin markdown ni texto alrededor. Las llaves van en inglés:
        {"cases":[{"stem":"...","setting":"#{Specialty::SETTING_SLUGS.keys.join("|")}",
        "questions":[{"text":"...","explanation":"...",
        "recommendation":1,"quote":"...","options":[{"text":"...","correct":true},
        {"text":"...","correct":false,"rationale":"..."},{"text":"...","correct":false,"rationale":"..."},
        {"text":"...","correct":false,"rationale":"..."}]}]}]}

        Recomendaciones:
        #{listing}
      TEXT
    end

    private

    attr_reader :guideline, :recommendations, :detail, :locale

    # Numbered from 1. The model cites a statement by this number, and
    # Questions::CaseBuilder maps it back to the row.
    def listing
      recommendations.map.with_index(1) { |recommendation, i| "#{i}. #{recommendation.text.squish}" }.join("\n")
    end

    def questions_per_case
      QUESTIONS_BY_DETAIL.fetch(detail)
    end

    # The extra material in a full workup is realistic completeness, not misdirection:
    # normal findings and background history belong in a real chart, and deciding what
    # matters is the skill being tested. Inventing misleading findings would be a
    # different thing entirely.
    def vignette_instructions
      return <<~TEXT.strip if detail == :focused
        La viñeta es breve y centrada (100 a 130 palabras), pero trae al paciente: edad,
        sexo, antecedentes relevantes con su duración, motivo de consulta con su evolución,
        signos vitales con unidades y la exploración física dirigida, con algún hallazgo
        normal. No todo reactivo del examen real es largo, pero ninguno omite al paciente.
      TEXT

      <<~TEXT.strip
        La viñeta debe presentar al paciente COMPLETO, como en el examen real (150 a 200
        palabras; menos de 150 es demasiado corta):
        - Edad, sexo y antecedentes con su duración y tratamiento ("diabetes mellitus tipo 2
          de 12 años en manejo irregular", "hipertensión controlada con IECA").
        - Motivo de consulta con inicio, duración y evolución precisas.
        - Signos vitales COMPLETOS con unidades: TA, FC, FR, SatO2, temperatura.
        - Exploración física sistemática, incluyendo hallazgos normales.
        - Cuando la recomendación lo justifique, resultados de laboratorio con sus valores.

        Incluye datos clínicos reales que NO apuntan a la respuesta: antecedentes de fondo,
        hallazgos normales, cifras dentro de rango. No son distractores ni pistas falsas —
        son lo que trae cualquier paciente real, y distinguir lo relevante es justo lo que
        el reactivo evalúa. Nunca inventes hallazgos que contradigan el diagnóstico.

        Las #{questions_per_case} preguntas se apoyan en el mismo caso, cada una sobre un
        aspecto distinto.
      TEXT
    end

    # The quote stays in Spanish so the citation gate can still find it in the statement.
    def language_instructions
      return "" unless locale == "en"

      "\nEscribe la viñeta, las preguntas, las opciones y las explicaciones EN INGLÉS. " \
        "La cita textual se queda en español, tal como aparece en la recomendación.\n"
    end
  end
end
