require "rails_helper"

RSpec.describe Questions::CaseGenerator do
  # Long enough to pass CaseBuilder's length floor, the way a real vignette is.
  let(:stem) do
    "Paciente masculino de 54 años con diabetes mellitus tipo 2 de 10 años en manejo con " \
      "metformina e hipertensión arterial de 6 años con losartán, que acude a urgencias por " \
      "dolor torácico opresivo de 40 minutos de evolución, irradiado a brazo izquierdo y " \
      "acompañado de diaforesis. Signos vitales: TA 150/90 mmHg, FC 104 lpm, FR 22 rpm, " \
      "SatO2 94% al aire ambiente, temperatura 36.7 °C. A la exploración, ruidos cardiacos " \
      "rítmicos sin soplos, campos pulmonares bien ventilados, abdomen blando sin dolor, " \
      "pulsos periféricos presentes y simétricos, sin edema de miembros inferiores."
  end

  let(:guideline) { create(:guideline, year: Date.current.year) }
  let(:section) { create(:guideline_section, guideline: guideline, kind: "recommendation") }
  let!(:recommendation) do
    create(
      :recommendation, guideline_section: section, grade: "A",
      text: "Se recomienda realizar electrocardiograma de 12 derivaciones."
    )
  end

  def stub_model(payload)
    allow(Llm::Completion).to receive(:call).and_return(
      ApplicationService::Response.new(
        success: true, errors: nil,
        payload: { content: payload.is_a?(String) ? payload : payload.to_json,
                   input_tokens: 600, output_tokens: 1_200, reasoning_tokens: 0, cost_usd: 0.00195 }
      )
    )
  end

  def options(correct_count: 1, total: 4)
    Array.new(total) { |i| { "text" => "Opción #{i}", "correct" => i < correct_count } }
  end

  def question(quote: "electrocardiograma de 12 derivaciones", index: 1, **overrides)
    { "text" => "¿Cuál es el estudio inicial?", "explanation" => "Porque sí",
      "recommendation" => index, "quote" => quote, "options" => options }.merge(overrides)
  end

  def one_case(*questions)
    { "cases" => [{ "stem" => stem, "questions" => questions }] }
  end

  it "refuses a guideline with no actionable recommendations" do
    empty = create(:guideline)

    result = described_class.call(empty)

    expect(result).to be_failure
    expect(result.errors.full_messages.to_sentence).to include("no tiene recomendaciones")
  end

  it "takes by default only what the screen left for a general physician" do
    recommendation.update!(decision_kind: "process")

    expect(described_class.call(guideline)).to be_failure
  end

  it "passes the provider's failure through rather than inventing a case" do
    allow(Llm::Completion).to receive(:call).and_return(
      ApplicationService::Response.new(
        success: false, payload: nil,
        errors: ActiveModel::Errors.new(Object.new)
      )
    )

    expect(described_class.call(guideline)).to be_failure
  end

  it "fails when the model does not return JSON" do
    stub_model("lo siento, no puedo")

    result = described_class.call(guideline)

    expect(result).to be_failure
    expect(result.errors.full_messages.to_sentence).to include("JSON legible")
  end

  it "builds a case with its questions and options" do
    stub_model(one_case(question, question))

    result = described_class.call(guideline)
    kase = result.payload[:cases].first

    expect(result).to be_success
    expect(kase.stem).to include("dolor torácico")
    expect(kase.questions.size).to eq(2)
    expect(kase.questions.first.answer_options.size).to eq(4)
    expect(kase.questions.first.recommendation).to eq(recommendation)
  end

  describe "the generation run" do
    it "records tokens, cases and rejections" do
      run = create(:generation_run)
      stub_model(one_case(question, question, question(quote: "inventado")))

      described_class.call(guideline, run: run)

      expect(run.reload).to have_attributes(
        input_tokens: 600, output_tokens: 1_200, cost_usd: 0.00195,
        cases_created: 1, rejections: 1, attempts: 2, calls: 1,
        rejection_reasons: { "quote_not_in_recommendation" => 1 }
      )
    end

    it "adds each call's rejection reasons to what the run already counted" do
      run = create(:generation_run, rejection_reasons: { "quote_not_in_recommendation" => 2 })
      stub_model(one_case(question(quote: "inventado"), question(index: 9)))

      described_class.call(guideline, run: run)

      expect(run.reload.rejection_reasons).to eq("quote_not_in_recommendation" => 3, "unknown_recommendation" => 1)
    end

    # The tokens were spent whether or not the reply parses, and a spending cap that
    # does not see them lets a run of bad replies overshoot it.
    it "charges a reply it could not read" do
      run = create(:generation_run)
      stub_model("lo siento, no puedo")

      described_class.call(guideline, run: run)

      expect(run.reload).to have_attributes(input_tokens: 600, cost_usd: 0.00195, calls: 1, cases_created: 0)
    end

    it "works without a run at all" do
      stub_model(one_case(question, question))

      expect(described_class.call(guideline)).to be_success
    end
  end

  it "writes from the window of statements it is handed" do
    later = create(:recommendation, guideline_section: section, text: "Se recomienda iniciar aspirina 300 mg.")
    stub_model(one_case(question(quote: "iniciar aspirina 300 mg"), question(quote: "iniciar aspirina 300 mg")))

    result = described_class.call(guideline, recommendations: [later])

    expect(Llm::Completion).to have_received(:call) do |prompt:, **|
      expect(prompt).to include("1. Se recomienda iniciar aspirina 300 mg.")
      expect(prompt).not_to include("electrocardiograma")
    end
    expect(result.payload[:cases].sole.questions.map(&:recommendation)).to eq([later, later])
  end

  # The detail level and the language are the prompt's and the builder's business; this
  # only proves the generator hands them on.
  it "passes the rotation's choices through to the prompt and the saved case" do
    stub_model(one_case(question, question))

    kase = described_class.call(guideline, detail: :full_workup, locale: "en").payload[:cases].sole

    expect(kase.locale).to eq("en")
    expect(Llm::Completion).to have_received(:call) do |prompt:, **|
      expect(prompt).to include("paciente COMPLETO", "EN INGLÉS")
    end
  end

  it "reads JSON the model wrapped in a markdown fence" do
    stub_model("```json\n#{one_case(question, question).to_json}\n```")

    expect(described_class.call(guideline).payload[:cases].size).to eq(1)
  end
end
