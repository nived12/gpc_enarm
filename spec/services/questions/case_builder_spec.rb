require "rails_helper"

RSpec.describe Questions::CaseBuilder do
  # Long enough to pass the length floor, the way a real vignette is.
  let(:stem) do
    "Paciente masculino de 54 años con diabetes mellitus tipo 2 de 10 años en manejo con " \
      "metformina e hipertensión arterial de 6 años con losartán, que acude a urgencias por " \
      "dolor torácico opresivo de 40 minutos de evolución, irradiado a brazo izquierdo y " \
      "acompañado de diaforesis. Signos vitales: TA 150/90 mmHg, FC 104 lpm, FR 22 rpm, " \
      "SatO2 94% al aire ambiente, temperatura 36.7 °C. A la exploración, ruidos cardiacos " \
      "rítmicos sin soplos, campos pulmonares bien ventilados, abdomen blando sin dolor, " \
      "pulsos periféricos presentes y simétricos, sin edema de miembros inferiores."
  end

  let(:guideline) { create(:guideline) }
  let(:section) { create(:guideline_section, guideline: guideline, kind: "recommendation") }
  let(:recommendation) do
    create(
      :recommendation, guideline_section: section, grade: "A",
      text: "Se recomienda realizar electrocardiograma de 12 derivaciones."
    )
  end

  def options(correct_count: 1, total: 4)
    Array.new(total) { |i| { "text" => "Opción #{i}", "correct" => i < correct_count } }
  end

  def question(quote: "electrocardiograma de 12 derivaciones", number: 1, **overrides)
    { "text" => "¿Cuál es el estudio inicial?", "explanation" => "Porque sí",
      "recommendation" => number, "quote" => quote, "options" => options }.merge(overrides.stringify_keys)
  end

  def one_case(*questions)
    { "cases" => [{ "stem" => stem, "questions" => questions }] }
  end

  def build_from(payload, recommendations: [recommendation], **options)
    described_class.call(payload, guideline: guideline, recommendations: recommendations, **options).payload
  end

  it "saves a case with its questions and options" do
    kase = build_from(one_case(question, question))[:cases].sole

    expect(kase).to be_persisted
    expect(kase).to have_attributes(stem: stem, locale: "es", source: "gpc_generated", guideline: guideline)
    expect(kase.questions.size).to eq(2)
    expect(kase.questions.first.answer_options.size).to eq(4)
    expect(kase.questions.first.recommendation).to eq(recommendation)
  end

  it "keeps why each distractor is wrong, and nothing on the correct option" do
    opts = options.each_with_index.map { |option, i| option.merge("rationale" => "  Razón\n#{i}  ") }

    kase = build_from(one_case(question(options: opts), question))[:cases].sole

    rationales = kase.questions.first.answer_options.map(&:rationale)
    expect(rationales).to eq([nil, "Razón 1", "Razón 2", "Razón 3"])
  end

  it "records the language it was asked for" do
    expect(build_from(one_case(question, question), locale: "en")[:cases].sole.locale).to eq("en")
  end

  it "files the case under the guideline's main topic and its specialty" do
    topic = create(:guideline_topic, guideline: guideline).topic

    kase = build_from(one_case(question, question))[:cases].sole

    expect(kase).to have_attributes(topic: topic, specialty: topic.branch.specialty)
  end

  describe "the setting the model names" do
    def with_setting(code, count: 1)
      { "cases" => Array.new(count) do |i|
        { "stem" => "#{stem} Caso #{i}.", "setting" => code, "questions" => [question, question] }
      end }
    end

    it "files the case under the context it names" do
      emergency = create(:emergency_setting)

      expect(build_from(with_setting("emergency"))[:cases].sole.setting).to eq(emergency)
    end

    it "reads the code once for every case that names it" do
      family = create(:family_medicine_setting)

      expect(build_from(with_setting("family_medicine", count: 2))[:cases].map(&:setting)).to eq([family, family])
    end

    it "keeps the case with an unknown setting when the code is made up" do
      create(:emergency_setting)

      built = build_from(with_setting("hospital_ward"))

      expect(built[:cases].sole.setting).to be_nil
      expect(built[:rejected]).to eq(0)
    end

    it "keeps the case with an unknown setting when the model names none" do
      create(:emergency_setting)

      expect(build_from(one_case(question, question))[:cases].sole.setting).to be_nil
    end
  end

  describe "what it refuses to keep" do
    it "drops a question whose quote is not in the recommendation" do
      built = build_from(one_case(question(quote: "angiografía coronaria inmediata")))

      expect(built).to eq(cases: [], rejected: 1, reasons: { "quote_not_in_recommendation" => 1 })
    end

    it "drops a question that does not offer exactly four options" do
      built = build_from(one_case(question(options: options(total: 3))))

      expect(built).to eq(cases: [], rejected: 1, reasons: { "wrong_option_count" => 1 })
    end

    it "drops a question with more than one correct answer" do
      built = build_from(one_case(question(options: options(correct_count: 2))))

      expect(built).to eq(cases: [], rejected: 1, reasons: { "not_one_correct" => 1 })
    end

    it "drops a question that is missing its text, and says it was incomplete" do
      expect(build_from(one_case(question(text: "")))[:reasons]).to eq("incomplete" => 1)
    end

    # The model numbers the statements itself. Number 0 once read as "the last one".
    it "drops a question citing a statement number that was never sent" do
      expect(build_from(one_case(question(number: 99)))[:reasons]).to eq("unknown_recommendation" => 1)
      expect(build_from(one_case(question(number: 0)))[:cases]).to be_empty
    end

    describe "a vignette that asks its own question" do
      def case_with_stem(stem, *questions)
        { "cases" => [{ "stem" => stem, "questions" => questions.presence || [question, question] }] }
      end

      # Case 250 of the pilot: the student read a question nobody answered above the one
      # they were asked. The whole case goes, and every question in it counts as rejected.
      it "rejects the whole case when the stem ends in a question" do
        built = build_from(case_with_stem("Paciente de 54 años con dolor torácico. ¿Cuál es la conducta inicial?"))

        expect(built).to eq(cases: [], rejected: 2, reasons: { "stem_asks_question" => 2 })
      end

      it "sees the question mark through a closing quote or bracket, and in English" do
        expect(build_from(case_with_stem("A 54-year-old man. What is the next step?\""))[:cases]).to be_empty
        expect(build_from(case_with_stem("Paciente de 54 años (¿dolor típico?) "))[:cases]).to be_empty
      end

      it "rejects a stem that repeats a question's text without the marks" do
        stem = "Paciente de 54 años con dolor torácico. Cuál es el estudio inicial"

        expect(build_from(case_with_stem(stem))[:reasons]).to eq("stem_asks_question" => 2)
      end

      it "keeps a stem that only quotes a short question or asks mid-sentence" do
        quoting = "#{stem} La esposa pregunta: ¿es grave? Refiere que nunca había tenido dolor así."
        short = question(text: "¿Diagnóstico?")

        expect(build_from(case_with_stem(quoting, short, short))[:cases].size).to eq(1)
      end
    end

    it "keeps the good questions in a case that also had a bad one" do
      built = build_from(one_case(question, question(quote: "inventado"), question))

      expect(built[:cases].sole.questions.size).to eq(2)
      expect(built[:rejected]).to eq(1)
    end

    # The validation batch's short cases (52–90 words) were the thin ones; the real
    # exam's are 150–200.
    it "rejects the whole case when the vignette is shorter than the floor" do
      short_stem = stem.split.first(described_class::MIN_STEM_WORDS - 1).join(" ")
      built = build_from({ "cases" => [{ "stem" => short_stem, "questions" => [question, question] }] })

      expect(built).to eq(cases: [], rejected: 2, reasons: { "stem_too_short" => 2 })
    end

    it "drops a case left with one question, since the exam asks two or three per case" do
      built = build_from(one_case(question, question(quote: "inventado")))

      expect(built).to eq(
        cases: [], rejected: 2, reasons: { "quote_not_in_recommendation" => 1, "too_few_questions" => 1 }
      )
    end

    it "skips a case with no vignette or no questions" do
      payload = { "cases" => [
        { "stem" => "", "questions" => [question] },
        { "stem" => "Paciente.", "questions" => [] }
      ] }

      expect(build_from(payload)[:cases]).to be_empty
    end
  end

  # A case that reads "Pregunta 1, Pregunta 3" to a student is a bug the reviewer sees
  # before the student does.
  it "numbers the questions that survived, not the ones the model sent" do
    kase = build_from(one_case(question, question(number: 99), question))[:cases].sole

    expect(kase.questions.pluck(:position)).to eq([1, 2])
  end

  describe "difficulty" do
    def difficulty_for(grade)
      recommendation.update!(grade: grade)
      build_from(one_case(question, question))[:cases].sole.difficulty
    end

    it "calls a case from strong evidence an easier item and one from weak evidence a harder one" do
      expect(difficulty_for("A")).to eq("low")
      expect(difficulty_for("D")).to eq("high")
    end

    it "sits in the middle for a grade it does not recognise, or no grade at all" do
      expect(difficulty_for("2b")).to eq("medium")
      expect(difficulty_for(nil)).to eq("medium")
    end
  end
end
