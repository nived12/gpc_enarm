# The second opinion, from another model family, on a case the generator already wrote.
#
# Every automated structural check — valid JSON, four options, exactly one correct, a
# citation that survives the substring gate — passes at 100% on every provider measured.
# None of them can see whether the option marked correct is the one the recommendation
# actually supports, and that is the failure a cheap generator would produce.
#
# So the verifier is not asked to grade the generator's answer. It is asked to answer the
# question itself, from the recommendation alone, and the verdict comes from whether it
# lands on the same option. A model shown which answer is marked correct agrees with it;
# a model asked to choose has to disagree out loud.
module Questions
  class Verifier < ApplicationService
    MAX_TOKENS = 2_000

    # Worst wins. A case is a unit — exams select whole cases — so one question whose
    # answer another family disputes holds the whole case back.
    SEVERITY = %w[unsupported ambiguous flawed supported].freeze

    # Item-writing defects that make a question easier than the real exam, found reading
    # the validation batch (2026-09-25). None needs the marked answer, so asking for them
    # leaves the blind answering intact. The second pilot showed the verifier calling a
    # correct option that echoes the recommendation a giveaway; the student never sees the
    # recommendation, so the prompt says that is expected. The last four came from reading
    # the first 500-call chunk, and are the only judgements the verifier may make from its
    # own medical knowledge: whether the recommendation fits this patient at all cannot be
    # read from the recommendation. A code the model invents is ignored: only these
    # hold a case back, and each has a label a reviewer reads (review.flaws).
    FLAWS = %w[
      answer_in_stem other_patient repeats_question implausible_distractor giveaway_wording
      wrong_for_this_patient another_option_valid beyond_general_practice administrative_trivia
    ].freeze

    # Options go out lettered, as on the real exam. Numbered options were answered
    # zero-based often enough to record a verifier that agreed as one that disputed.
    LETTERS = %w[A B C D].freeze

    def initialize(clinical_case, run: nil)
      super()
      @clinical_case = clinical_case
      @run = run
    end

    def call
      return failure("El caso no tiene preguntas verificables") if questions.empty?

      completion = Llm::Completion.call(role: :verifier, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      record(completion.payload)
      judgements = Llm::Completion.json_in(completion.payload[:content])
      return failure("El verificador no devolvió JSON legible") if judgements.nil?

      verdict = apply(judgements)
      success(verdict: verdict, notes: clinical_case.verification_notes, rationales: rationales_for(verdict))
    end

    def context_for_logging
      { clinical_case_id: clinical_case.id }
    end

    private

    attr_reader :clinical_case, :run

    # Only questions that carry both a citation and a marked answer can be judged; a
    # question missing either was never verifiable and is not evidence against the case.
    def questions
      @questions ||= clinical_case.questions.select do |question|
        question.recommendation.present? && question.correct_option.present?
      end
    end

    def prompt
      <<~TEXT
        Eres médico revisor de reactivos del ENARM. Vas a responder preguntas de opción
        múltiple usando ÚNICAMENTE la recomendación de la guía de práctica clínica que se
        incluye con cada una. No uses conocimiento propio para elegir: si la recomendación
        no basta para decidir, dilo.

        Caso clínico:
        #{clinical_case.stem}

        #{questions.map.with_index(1) { |question, index| block_for(question, index) }.join("\n")}
        Para cada pregunta devuelve la letra de la opción que la recomendación respalda, y
        si la recomendación alcanza para decidirla.

        Revisa además cada pregunta como revisor del ENARM real, y anota en "flaws" los
        defectos claros que tenga, con estos códigos (lista vacía si no tiene ninguno):
        - answer_in_stem: la respuesta ya está escrita en la viñeta; basta con localizarla,
          no hay que razonar.
        - other_patient: la pregunta trata de otro paciente o de una situación hipotética
          ajena al caso.
        - repeats_question: pregunta lo mismo que otra pregunta del caso, con otras palabras.
        - implausible_distractor: alguna opción es absurda o nadie con formación médica la
          elegiría.
        - giveaway_wording: la viñeta o el enunciado de la pregunta contienen palabras que
          delatan la respuesta, o una opción destaca claramente de las demás por su forma.
        Para los cuatro siguientes usa tu conocimiento médico:
        - wrong_for_this_patient: la opción que la recomendación respalda no es la mejor
          conducta para el paciente tal como se describe (la recomendación aplica a otra
          situación, por ejemplo a un paciente estable o sin sangrado).
        - another_option_valid: otra opción también es válida o igual de adecuada.
        - beyond_general_practice: pregunta un detalle de subespecialidad que no se espera
          de un médico general (técnica o insumo quirúrgico, prueba o índice de especialista).
        - administrative_trivia: pregunta un dato administrativo (quién realiza un
          procedimiento, cómo se entrega la información) y no una decisión clínica.
        El alumno no ve la recomendación: que la opción respaldada repita su texto es lo
        esperado y no es un defecto. Tampoco lo es que la recomendación no alcance para
        decidir; eso ya lo dice "decidable". Marca solo defectos claros; en "note" di cuál
        es, en una oración.

        Devuelve SOLO JSON, sin markdown:
        {"questions":[{"question":1,"option":"B","decidable":true,"flaws":[],"note":"..."}]}
      TEXT
    end

    def block_for(question, index)
      options = question.answer_options.each_with_index.map { |option, index| "  #{LETTERS[index]}) #{option.text}" }

      <<~TEXT
        Pregunta #{index}: #{question.text}
        #{options.join("\n")}
        Recomendación: #{question.recommendation.text.squish}
      TEXT
    end

    def apply(judgements)
      verdicts = Array(judgements["questions"]).filter_map { |judgement| judge(judgement) }
      verdict = worst(verdicts)

      clinical_case.update!(
        verification_verdict: verdict, verified_at: Time.current, status: clinical_case.status_after_verdict(verdict),
        verification_notes: verdicts.map(&:last).compact_blank.join("\n").presence
      )
      verdict
    end

    # Silence from the second opinion is not assent: a verifier that answered two of a
    # case's three questions has not cleared the third, so the case cannot pass on what
    # it did say.
    def worst(verdicts)
      verdict = SEVERITY.find { |candidate| verdicts.any? { |row| row.first == candidate } }
      return "ambiguous" if verdict.nil? || (verdict == "supported" && verdicts.size < questions.size)

      verdict
    end

    # A question the verifier never answered is not a pass. Silence from the second
    # opinion is not assent, and the case waits rather than going live unexamined.
    #
    # Only a readable choice of a different option is a dispute. A verifier that says the
    # statement cannot settle the question has guessed its option, and one whose answer
    # cannot be read has said nothing; both leave the case ambiguous, for a person to read.
    def judge(judgement)
      question = questions[judgement["question"].to_i - 1]
      return if question.nil?

      chosen = option_at(question, judgement["option"])
      note = ["#{question.position}.", judgement["note"]].compact_blank.join(" ")

      return ["ambiguous", note] if !judgement["decidable"] || chosen.nil?
      return ["unsupported", note] unless chosen.correct?

      flaws = FLAWS & Array(judgement["flaws"]).map(&:to_s)
      return ["supported", nil] if flaws.empty?

      labels = flaws.map { |flaw| I18n.t("review.flaws.#{flaw}") }.join(", ")
      ["flawed", ["#{question.position}.", "#{labels}.", judgement["note"]].compact_blank.join(" ")]
    end

    def option_at(question, letter)
      index = LETTERS.index(letter.to_s.strip.upcase)
      question.answer_options[index] if index
    end

    # Only a case that can go live has its rationales judged: an unsupported case never
    # reaches a student, and paying to check its prose buys nothing. A failed judgement
    # leaves them unjudged for questions:verify_rationales, and never fails the verdict.
    def rationales_for(verdict)
      return unless verdict == "supported"

      unjudged = AnswerOption.rationale_unjudged.joins(:question)
                             .where(questions: { clinical_case_id: clinical_case.id })
      return unless unjudged.exists?

      result = RationaleVerifier.call(clinical_case, run: run)
      result.success? ? result.payload : { error: result.errors.full_messages.to_sentence }
    end

    def record(usage)
      return if run.nil?

      run.charge!(usage)
      run.increment!(:attempts, 1)
    end
  end
end
