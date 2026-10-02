FactoryBot.define do
  factory :generation_run do
    purpose { "generation" }
    provider { "gemini" }
    model { "gemini-3.1-flash-lite" }
    status { "running" }
    started_at { Time.current }
  end

  factory :clinical_case do
    stem { "Paciente de 54 años acude por dolor torácico opresivo de dos horas de evolución." }
    locale { "es" }
    difficulty { "medium" }
    status { "draft" }
    source { "gpc_generated" }
  end

  factory :question do
    clinical_case
    sequence(:position) { |n| n }
    text { "¿Cuál es el estudio inicial indicado?" }
    explanation { "El electrocardiograma se realiza en los primeros diez minutos." }
  end

  factory :answer_option do
    question
    sequence(:position) { |n| n }
    text { "Electrocardiograma de 12 derivaciones" }
    correct { false }
  end

  # A case as a student meets it: published, supported by the second opinion, and every
  # question citing a statement of its guideline, with B as the right answer. With
  # `figure: true` the first statement points at a stored CUADRO 2, the way roughly one
  # recommendation in twelve does.
  factory :published_case, parent: :clinical_case do
    status { "published" }
    verification_verdict { "supported" }
    guideline

    transient do
      questions_count { 2 }
      figure { false }
      best_available { false }
    end

    after(:create) do |kase, context|
      section = create(:guideline_section, guideline: kase.guideline)
      if context.figure
        create(
          :clinical_image, :stored, label: "CUADRO 2",
          guideline_section: create(:guideline_section, guideline: kase.guideline)
        )
      end

      context.questions_count.times do |index|
        pointer = " (ver cuadro 2)" if context.figure && index.zero?
        recommendation = create(
          :recommendation, guideline_section: section,
          text: "Se recomienda realizar electrocardiograma de 12 derivaciones en los primeros diez minutos#{pointer}."
        )
        question = create(
          :question, clinical_case: kase, position: index + 1, recommendation: recommendation,
          text: "Pregunta #{index + 1} del caso #{kase.id}: ¿cuál es el estudio inicial?",
          source_quote: "electrocardiograma de 12 derivaciones"
        )
        ["Troponina I", "Electrocardiograma de 12 derivaciones", "Radiografía de tórax", "Ecocardiograma"]
          .each.with_index(1) do |text, position|
            create(
              :answer_option, question: question, position: position, text: text, correct: position == 2,
              rationale: ("#{text} no es el estudio inicial: tarda en dar un resultado útil." unless position == 2)
            )
          end
        next unless context.best_available

        variant = create(
          :question, clinical_case: kase, position: index + 1, recommendation: recommendation, variant_of: question,
          text: question.text, source_quote: question.source_quote, best_available_verdict: "supported",
          explanation: "La ideal sería el electrocardiograma; de las ofrecidas, la troponina."
        )
        ["Troponina I", "Radiografía de tórax", "Ecocardiograma",
"Gasometría arterial"].each.with_index(1) do |text, position|
          create(:answer_option, question: variant, position: position, text: text, correct: position == 1)
        end
      end
    end
  end

  factory :exam do
    user
    mode { "quick_quiz" }
    status { "in_progress" }
    question_count { 10 }
    started_at { Time.current }
    running_since { Time.current }
  end
end
